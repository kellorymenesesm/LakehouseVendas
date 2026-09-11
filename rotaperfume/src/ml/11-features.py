# Databricks notebook source
# MAGIC %md
# MAGIC # Features de cliente -- o que se sabia dele ATE uma data
# MAGIC
# MAGIC A gold responde tudo sobre ontem. O modelo precisa de outra coisa: **uma
# MAGIC linha por cliente**, com tudo que era sabido sobre ele ate um corte, e nada
# MAGIC do que veio depois.
# MAGIC
# MAGIC Duas decisoes seguram este arquivo inteiro:
# MAGIC
# MAGIC 1. **A data de corte e parametro de funcao, nao disciplina pessoal.** Cada
# MAGIC    fonte e filtrada pela data dela na PRIMEIRA linha da leitura. O que o
# MAGIC    filtro nao deixa entrar nao tem como vazar para a feature.
# MAGIC 2. **Uma funcao, dois usos.** A mesma `montar_features()` gera o dado de
# MAGIC    treino (com rotulo) e o de score (sem rotulo). E impossivel os dois
# MAGIC    divergirem -- esse desencontro tem nome, *training/serving skew*, e e o
# MAGIC    que o Feature Store resolve com infraestrutura. Aqui esta resolvido com
# MAGIC    um `def`.
# MAGIC
# MAGIC **`gold.dim_cliente` NAO entra aqui.** `dias_sem_comprar`,
# MAGIC `receita_acumulada` e `total_pedidos` agregam a base inteira, sem corte:
# MAGIC usar qualquer uma e vazamento. Ela so volta no prompt 3, para nome e cidade.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")

catalog = dbutils.widgets.get("catalog")

# O "hoje" deste dataset e 2026-08-31 -- a ultima data de pedido do fato.
# Nada de current_date() em lugar nenhum: o dado nao envelhece junto com o
# relogio da sala, e um notebook que depende de quando roda nao e reprodutivel.
REFERENCIA_TREINO = "2026-08-01"   # corte do treino: 30 dias antes do fim
REFERENCIA_SCORE = "2026-08-31"    # corte do score: o "hoje"
JANELA_ALVO_DIAS = 7               # a fila e semanal, o rotulo tambem

print(f"catalogo ...........: {catalog}")
print(f"corte do treino ....: {REFERENCIA_TREINO}  (+ alvo de {JANELA_ALVO_DIAS} dias)")
print(f"corte do score .....: {REFERENCIA_SCORE}  (sem alvo)")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A funcao
# MAGIC
# MAGIC Vinte features em quatro grupos: **RFM**, **Ritmo**, **CRM** e **Mix**.
# MAGIC
# MAGIC `recencia_dias` esta em qualquer tutorial. `atraso_relativo` nao esta em
# MAGIC nenhum, porque depende de saber que distribuicao funciona por ciclo de
# MAGIC reposicao: dois clientes sumidos ha 27 dias sao casos opostos se um compra
# MAGIC a cada 24 dias e o outro a cada 139.

# COMMAND ----------

from pyspark.sql import DataFrame, Window
from pyspark.sql import functions as F


def montar_features(referencia: str) -> DataFrame:
    """Uma linha por cliente com tudo que se sabia dele ATE `referencia` (exclusive).

    `referencia` e uma data ISO ('2026-08-31'). Toda fonte e filtrada pela data
    dela logo na leitura -- e por isso que nao ha como uma feature enxergar o
    futuro.
    """
    corte = F.to_date(F.lit(referencia))
    corte_90d = F.date_sub(corte, 90)
    corte_120d = F.date_sub(corte, 120)

    # --- as tres fontes, cada uma cortada na primeira linha -------------------
    fato = spark.table(f"{catalog}.gold.fato_vendas").filter(F.col("data_pedido") < corte)
    oportunidades = spark.table(f"{catalog}.silver.oportunidades").filter(F.col("data_abertura") < corte)
    visitas = spark.table(f"{catalog}.silver.visitas").filter(F.col("data_visita") < corte)

    # -------------------------------------------------------------------------
    # GRUPO 1 - RFM. Recencia, frequencia e valor, o trio classico, mais margem.
    # Devolucao ja entra negativa no fato: nao ha o que descontar aqui.
    # -------------------------------------------------------------------------
    rfm = fato.groupBy("cliente_id").agg(
        F.datediff(corte, F.max("data_pedido")).alias("recencia_dias"),
        F.countDistinct("pedido_id").alias("frequencia_pedidos"),
        F.sum("receita").alias("valor_total"),
        F.sum("margem").alias("margem_total"),
        F.countDistinct(F.when(F.col("data_pedido") >= corte_90d, F.col("pedido_id"))).alias("pedidos_ultimos_90d"),
    )
    rfm = (
        rfm
        .withColumn("ticket_medio", F.col("valor_total") / F.nullif(F.col("frequencia_pedidos"), F.lit(0)))
        .withColumn("margem_percentual", F.col("margem_total") / F.nullif(F.col("valor_total"), F.lit(0)))
    )

    # -------------------------------------------------------------------------
    # GRUPO 2 - Ritmo. Os gaps entre pedidos consecutivos, calculados UMA vez:
    # media e desvio saem do mesmo lag(). Datas DISTINTAS de pedido -- o fato
    # esta no grao de item, e sete itens do mesmo pedido dariam seis gaps zero.
    # -------------------------------------------------------------------------
    janela_cliente = Window.partitionBy("cliente_id").orderBy("data_pedido")
    gaps = (
        fato.select("cliente_id", "data_pedido").distinct()
        .withColumn("gap_dias", F.datediff(F.col("data_pedido"), F.lag("data_pedido").over(janela_cliente)))
        .filter(F.col("gap_dias").isNotNull())
    )
    ritmo = gaps.groupBy("cliente_id").agg(
        F.avg("gap_dias").alias("intervalo_medio_dias"),
        F.stddev("gap_dias").alias("desvio_intervalo_dias"),
    )

    # -------------------------------------------------------------------------
    # GRUPO 3 - CRM. Oportunidades e visitas. Cliente sem nenhuma das duas fica
    # com 0, nao com NULL: "nunca teve oportunidade" e informacao, nao ausencia.
    # -------------------------------------------------------------------------
    crm = oportunidades.groupBy("cliente_id").agg(
        # em aberto = nem ganha nem perdida. As duas sao booleanas na silver.
        F.sum(
            F.when(~F.coalesce(F.col("ganha"), F.lit(False)) & ~F.coalesce(F.col("perdida"), F.lit(False)), 1)
            .otherwise(0)
        ).alias("oportunidades_abertas"),
        F.sum(F.when(F.col("ganha"), 1).otherwise(0)).alias("oportunidades_ganhas"),
        F.count(F.lit(1)).alias("_oportunidades_total"),
    )
    crm = crm.withColumn(
        "taxa_ganho", F.col("oportunidades_ganhas") / F.nullif(F.col("_oportunidades_total"), F.lit(0))
    ).drop("_oportunidades_total")

    # ARMADILHA DO AMBIENTE: silver.visitas NAO tem coluna gerou_pedido -- tem
    # `resultado`, texto, com cinco valores. Visita que virou pedido e
    # exatamente 'Pedido realizado'. A feature nasce aqui, de uma regra escrita
    # uma vez, e nao de cinco `when` espalhados pelo notebook.
    visitas = visitas.withColumn("gerou_pedido", F.col("resultado") == F.lit("Pedido realizado"))
    crm_visitas = visitas.groupBy("cliente_id").agg(
        F.sum(F.when(F.col("data_visita") >= corte_90d, 1).otherwise(0)).alias("visitas_90d"),
        F.count(F.lit(1)).alias("_visitas_total"),
        F.sum(F.when(F.col("gerou_pedido"), 1).otherwise(0)).alias("_visitas_com_pedido"),
    )
    # conversao sobre TODO o historico ate o corte: a taxa de 90 dias oscila
    # demais para cliente com duas ou tres visitas no trimestre.
    crm_visitas = crm_visitas.withColumn(
        "conversao_visita", F.col("_visitas_com_pedido") / F.nullif(F.col("_visitas_total"), F.lit(0))
    ).drop("_visitas_total", "_visitas_com_pedido")

    # -------------------------------------------------------------------------
    # GRUPO 4 - Mix. O que ele compra, nao quanto. O fato ja traz categoria e
    # marca: nenhum join necessario ate o lancamento.
    # -------------------------------------------------------------------------
    mix = fato.groupBy("cliente_id").agg(
        F.countDistinct("sku").alias("skus_distintos"),
        F.countDistinct("categoria").alias("categorias_distintas"),
        F.countDistinct("marca").alias("marcas_distintas"),
    )

    receita_por_marca = fato.groupBy("cliente_id", "marca").agg(F.sum("receita").alias("receita_marca"))
    marca_top = receita_por_marca.groupBy("cliente_id").agg(F.max("receita_marca").alias("_receita_marca_top"))

    # O UNICO join do notebook: dim_produto so pela data_lancamento. Lancamento
    # e o SKU que entrou na linha nos 120 dias anteriores ao corte -- comprar
    # novidade e sinal de cliente engajado, nao de cliente grande.
    lancamentos = (
        spark.table(f"{catalog}.gold.dim_produto")
        .filter((F.col("data_lancamento") >= corte_120d) & (F.col("data_lancamento") < corte))
        .select("sku")
    )
    comprou_lancamento = (
        fato.select("cliente_id", "sku")
        .join(lancamentos, on="sku", how="inner")
        .select("cliente_id").distinct()
        .withColumn("comprou_lancamento", F.lit(1))
    )

    # -------------------------------------------------------------------------
    # A juncao. A base e quem COMPROU ate o corte -- e o universo que o time
    # comercial liga. left join em tudo, porque CRM e mix sao opcionais.
    # -------------------------------------------------------------------------
    features = (
        rfm
        .join(ritmo, on="cliente_id", how="left")
        .join(crm, on="cliente_id", how="left")
        .join(crm_visitas, on="cliente_id", how="left")
        .join(mix, on="cliente_id", how="left")
        .join(marca_top, on="cliente_id", how="left")
        .join(comprou_lancamento, on="cliente_id", how="left")
    )

    features = features.withColumn(
        "concentracao_marca_top", F.col("_receita_marca_top") / F.nullif(F.col("valor_total"), F.lit(0))
    )

    # ARMADILHA MEDIDA: F.least() IGNORA nulo e devolve o outro valor. Sem o
    # `when` de fora, os clientes de UM pedido so (intervalo NULL) recebem o
    # teto 10 e vao para o TOPO da fila -- os primeiros lugares entregues a quem
    # nunca repetiu compra. O teto so existe para quem tem ritmo medido.
    tem_ritmo = F.col("intervalo_medio_dias").isNotNull() & (F.col("intervalo_medio_dias") > 0)
    features = features.withColumn(
        "atraso_relativo",
        F.when(tem_ritmo, F.least(F.col("recencia_dias") / F.col("intervalo_medio_dias"), F.lit(10.0))),
    )

    # Sem oportunidade e sem visita e ZERO, nao NULL. So o ritmo pode ser NULL,
    # e por um motivo real: cliente de um pedido so nao tem intervalo nenhum.
    zerados = [
        "oportunidades_abertas", "oportunidades_ganhas", "taxa_ganho",
        "visitas_90d", "conversao_visita",
        "skus_distintos", "categorias_distintas", "marcas_distintas",
        "concentracao_marca_top", "comprou_lancamento",
    ]
    features = features.fillna(0, subset=zerados)

    # Toda soma de receita ou margem sai da gold como DECIMAL. Sem o cast, o
    # registro do modelo quebra la na frente com "Object of type Decimal is not
    # JSON serializable" -- erro que aparece a tres prompts de distancia daqui.
    numericas = [
        "recencia_dias", "frequencia_pedidos", "valor_total", "ticket_medio",
        "margem_total", "margem_percentual",
        "intervalo_medio_dias", "desvio_intervalo_dias", "atraso_relativo", "pedidos_ultimos_90d",
        "oportunidades_abertas", "oportunidades_ganhas", "taxa_ganho", "visitas_90d", "conversao_visita",
        "skus_distintos", "categorias_distintas", "marcas_distintas",
        "concentracao_marca_top", "comprou_lancamento",
    ]
    for coluna in numericas:
        features = features.withColumn(coluna, F.col(coluna).cast("double"))

    # A data de corte nao e comentario no codigo: e COLUNA na tabela. Quem abrir
    # a tabela daqui a seis meses sabe de que dia era o retrato.
    return features.select(
        "cliente_id",
        *numericas,
        corte.alias("_referencia"),
    )

# COMMAND ----------

# MAGIC %md
# MAGIC ## Tabela 1 -- treino, com rotulo
# MAGIC
# MAGIC Corte em **2026-08-01**, e o alvo olha os **7 dias seguintes**. A janela e
# MAGIC de sete dias porque a fila e semanal: o rotulo tem que ter o mesmo
# MAGIC horizonte da decisao. O time liga para 200 clientes por semana, entao a
# MAGIC pergunta e "compra nesta semana", nao "compra em algum momento do mes".

# COMMAND ----------

features_treino = montar_features(REFERENCIA_TREINO)

# O alvo le o fato SEM o corte -- de proposito, e so aqui. E a unica parte do
# notebook que enxerga depois da referencia, porque e exatamente isso que um
# rotulo e: o futuro que ja aconteceu, para o modelo aprender com ele.
inicio_alvo = F.to_date(F.lit(REFERENCIA_TREINO))
fim_alvo = F.date_add(inicio_alvo, JANELA_ALVO_DIAS - 1)

compradores_da_janela = (
    spark.table(f"{catalog}.gold.fato_vendas")
    .filter((F.col("data_pedido") >= inicio_alvo) & (F.col("data_pedido") <= fim_alvo))
    .select("cliente_id").distinct()
    .withColumn("comprou_em_7d", F.lit(1))
)

features_treino = (
    features_treino
    .join(compradores_da_janela, on="cliente_id", how="left")
    .fillna(0, subset=["comprou_em_7d"])
)

destino_treino = f"{catalog}.gold.features_treino"
(
    features_treino.write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(destino_treino)
)

# saveAsTable NAO grava comment de tabela: o COMMENT ON vem em seguida, sempre.
spark.sql(
    f"COMMENT ON TABLE {destino_treino} IS "
    f"'Features de cliente no corte de {REFERENCIA_TREINO} mais o alvo comprou_em_7d "
    f"(fez pedido nos {JANELA_ALVO_DIAS} dias seguintes). Uma linha por cliente, gerada pela "
    "mesma funcao montar_features de gold.features_cliente -- e o dataset de treino do modelo de propensao.'"
)

print(f"gravado: {destino_treino}")

# COMMAND ----------

# A taxa base -- o numero que vira regua no proximo prompt. E o resultado de
# ligar para 200 clientes as cegas.
base = features_treino.agg(
    F.count(F.lit(1)).alias("clientes"),
    F.sum("comprou_em_7d").alias("compraram"),
    F.avg("comprou_em_7d").alias("taxa"),
).collect()[0]

print(f"clientes ...: {base['clientes']:,}")
print(f"compraram ..: {int(base['compraram']):,} nos {JANELA_ALVO_DIAS} dias seguintes")
print(f"TAXA BASE ..: {100 * base['taxa']:.2f}%  -> {round(200 * base['taxa'])} de cada 200 ligacoes as cegas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## Tabela 2 -- score, sem rotulo
# MAGIC
# MAGIC A MESMA funcao, so trocando a data. Corte em **2026-08-31**, o "hoje" do
# MAGIC dataset: nao ha rotulo porque a semana ainda nao aconteceu. E esta a
# MAGIC tabela que vai ser pontuada.

# COMMAND ----------

features_cliente = montar_features(REFERENCIA_SCORE)

destino_cliente = f"{catalog}.gold.features_cliente"
(
    features_cliente.write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(destino_cliente)
)

spark.sql(
    f"COMMENT ON TABLE {destino_cliente} IS "
    f"'Features de cliente no corte de {REFERENCIA_SCORE} (o hoje do dataset), sem alvo -- "
    "e a tabela que o modelo pontua para montar a fila semanal de ligacoes. Gerada pela mesma "
    "funcao montar_features de gold.features_treino, o que impede training/serving skew.'"
)

print(f"gravado: {destino_cliente}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## A conferencia que importa: nao ha vazamento
# MAGIC
# MAGIC Recencia negativa significa que uma fonte escapou do filtro -- e o cliente
# MAGIC "comprou depois do corte" dentro de uma feature que deveria ignorar isso.
# MAGIC E a assinatura do vazamento, e vale parar o notebook.

# COMMAND ----------

for nome, tabela in [("treino", destino_treino), ("cliente", destino_cliente)]:
    linha = spark.table(tabela).agg(
        F.count(F.lit(1)).alias("clientes"),
        F.min("_referencia").alias("corte"),
        F.min("recencia_dias").alias("menor_recencia"),
        F.max("atraso_relativo").alias("maior_atraso"),
    ).collect()[0]

    print(
        f"{nome:<8} {linha['clientes']:>6,} clientes   corte {linha['corte']}   "
        f"menor recencia {linha['menor_recencia']:.0f}   maior atraso {linha['maior_atraso']:.1f}"
    )

    if linha["menor_recencia"] < 0:
        raise Exception(
            f"VAZAMENTO em {tabela}: recencia_dias negativa ({linha['menor_recencia']:.0f}). "
            "Alguma fonte nao foi filtrada por '< referencia'."
        )

print("\nOK: nenhuma recencia negativa -- o corte segurou nas duas tabelas.")

# COMMAND ----------

# A feature que ordena a fila. Dois clientes com a MESMA recencia aparecem em
# posicoes opostas aqui -- e esse o ponto do prompt inteiro.
display(
    spark.sql(f"""
        SELECT c.razao_social,
               f.recencia_dias,
               ROUND(f.intervalo_medio_dias, 1) AS intervalo_medio,
               ROUND(f.atraso_relativo, 1)      AS atraso
        FROM {catalog}.gold.features_cliente f
        JOIN {catalog}.gold.dim_cliente c USING (cliente_id)
        ORDER BY f.atraso_relativo DESC
        LIMIT 10
    """)
)
