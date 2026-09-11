# Databricks notebook source
# MAGIC %md
# MAGIC # Conferencia de chegada do raw
# MAGIC
# MAGIC A tarefa mais chata do pipeline e a que mais salva emprego.
# MAGIC
# MAGIC Arquivo que nao chega **nao da erro**: da numero menor, com cara de numero
# MAGIC certo. Entao antes de qualquer transformacao, alguem precisa conferir o que
# MAGIC chegou -- e parar o pipeline se faltar alguma coisa.
# MAGIC
# MAGIC Aqui o dado ainda e **arquivo**, nao tabela. A unica tabela que este
# MAGIC notebook escreve e a de controle: `bronze._raw_arquivos`.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")

catalog = dbutils.widgets.get("catalog")
volume = f"/Volumes/{catalog}/bronze/raw"
tabela_controle = f"{catalog}.bronze._raw_arquivos"

# Os 10 arquivos que TEM que estar la. A lista e explicita de proposito: e ela
# que transforma "chegou alguma coisa" em "chegou exatamente o que era esperado".
ESPERADOS = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}

print(f"catalogo ....: {catalog}")
print(f"volume ......: {volume}")
print(f"esperados ...: {sum(len(v) for v in ESPERADOS.values())} arquivos")

# COMMAND ----------

# Inventario do que realmente esta no Volume, por sistema.
presentes = {}
for sistema in ESPERADOS:
    try:
        presentes[sistema] = {f.name: f.size for f in dbutils.fs.ls(f"{volume}/{sistema}")}
    except Exception as erro:
        # Pasta inexistente e um caso de falta, nao um crash sem explicacao.
        print(f"AVISO: nao consegui listar {volume}/{sistema}: {erro}")
        presentes[sistema] = {}

# COMMAND ----------

from datetime import datetime, timezone

conferidos = []   # o que chegou, com bytes e linhas
problemas = []    # o que faltou ou veio vazio

for sistema, arquivos in ESPERADOS.items():
    for nome in arquivos:
        arquivo = f"{nome}.csv"
        tamanho = presentes[sistema].get(arquivo)

        if tamanho is None:
            problemas.append(f"FALTOU     {sistema}/{arquivo}")
            continue
        if tamanho == 0:
            problemas.append(f"VAZIO (0B) {sistema}/{arquivo}")
            continue

        # Linhas de DADO: o leitor de texto conta linhas fisicas, entao desconta
        # o cabecalho. Nenhum dos 10 arquivos tem quebra de linha dentro de campo.
        linhas = spark.read.text(f"{volume}/{sistema}/{arquivo}").count() - 1
        if linhas <= 0:
            problemas.append(f"SO CABECALHO {sistema}/{arquivo}")
            continue

        conferidos.append((sistema, arquivo, int(tamanho), int(linhas)))

print(f"conferidos: {len(conferidos)}   problemas: {len(problemas)}")

# COMMAND ----------

# Grava a tabela de controle ANTES de decidir se falha: mesmo numa noite ruim,
# fica o registro do que chegou e do que nao chegou.
from pyspark.sql.functions import current_timestamp
from pyspark.sql.types import StructType, StructField, StringType, LongType

schema = StructType([
    StructField("sistema", StringType(), False),
    StructField("arquivo", StringType(), False),
    StructField("bytes", LongType(), False),
    StructField("linhas", LongType(), False),
])

(
    spark.createDataFrame(conferidos, schema)
    .withColumn("conferido_em", current_timestamp())
    .write.mode("overwrite")
    .option("overwriteSchema", "true")
    .saveAsTable(tabela_controle)
)

spark.sql(
    f"COMMENT ON TABLE {tabela_controle} IS "
    "'Controle de chegada do raw: um registro por arquivo que chegou ao Volume, "
    "com tamanho e numero de linhas na hora da conferencia.'"
)

print(f"gravado: {tabela_controle}")

# COMMAND ----------

# Relatorio legivel -- e o que a turma ve na saida do job.
larg = max(len(a) for _, a, _, _ in conferidos) if conferidos else 20
print(f"{'SISTEMA':<8} {'ARQUIVO':<{larg}} {'BYTES':>12} {'LINHAS':>10}")
print("-" * (8 + larg + 12 + 10 + 3))
for sistema, arquivo, tamanho, linhas in sorted(conferidos, key=lambda r: -r[3]):
    print(f"{sistema:<8} {arquivo:<{larg}} {tamanho:>12,} {linhas:>10,}")
print("-" * (8 + larg + 12 + 10 + 3))
print(
    f"{'TOTAL':<8} {len(conferidos):<{larg}} "
    f"{sum(r[2] for r in conferidos):>12,} {sum(r[3] for r in conferidos):>10,}"
)
print(f"\n{sum(r[2] for r in conferidos) / 1024 / 1024:.1f} MB conferidos em "
      f"{datetime.now(timezone.utc).isoformat(timespec='seconds')}")

# COMMAND ----------

# O ponto da tarefa: se faltou arquivo, o job PARA aqui. Sem isso o pipeline
# seguiria verde, a bronze teria nove tabelas em vez de dez, e o dashboard
# mostraria um faturamento menor -- com cara de numero certo.
if problemas:
    raise Exception(
        "Conferencia de chegada FALHOU -- "
        f"{len(problemas)} de {sum(len(v) for v in ESPERADOS.values())} arquivos com problema:\n  "
        + "\n  ".join(problemas)
        + f"\n\nRode: bash scripts/subir-raw.sh <profile>"
    )

print("OK: os 10 arquivos chegaram inteiros.")
