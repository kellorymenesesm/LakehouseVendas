# Databricks notebook source
# MAGIC %md
# MAGIC # Ingestao da bronze
# MAGIC
# MAGIC Dez tabelas Delta a partir dos dez CSVs do Volume. Uma funcao e uma lista --
# MAGIC se amanha o ERP mandar a decima primeira, e uma linha.
# MAGIC
# MAGIC **A regra da bronze: nao conserta nada.** Tudo entra como texto, de
# MAGIC proposito. Se o Spark adivinhasse o tipo, a sujeira sumiria antes de alguem
# MAGIC ver que ela existiu -- e no dia em que o numero desse errado la na frente,
# MAGIC ninguem saberia se o erro veio da origem ou da limpeza.
# MAGIC
# MAGIC A conversao e trabalho da silver, feita sabendo o que se faz.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")

catalog = dbutils.widgets.get("catalog")
volume = f"/Volumes/{catalog}/bronze/raw"
controle = f"{catalog}.bronze._raw_arquivos"

# A mesma lista de src/raw/conferencia.py: e ela que o laco percorre.
ORIGEM = {
    "erp": ["produtos", "pedidos", "itens_pedido", "pagamentos", "estoque"],
    "crm": ["clientes", "vendedores", "carteira", "oportunidades", "visitas"],
}
NOME_DO_SISTEMA = {"erp": "ERP", "crm": "CRM"}

print(f"catalogo ..: {catalog}")
print(f"volume ....: {volume}")
print(f"tabelas ...: {sum(len(t) for t in ORIGEM.values())}")

# COMMAND ----------

from pyspark.sql.functions import col, current_timestamp


def ingerir(sistema: str, tabela: str) -> int:
    """Le um CSV do Volume e grava a tabela bronze correspondente. Devolve as linhas gravadas."""
    caminho = f"{volume}/{sistema}/{tabela}.csv"
    destino = f"{catalog}.bronze.{tabela}"

    df = (
        spark.read
        # header sim; inferSchema NAO -- e a decisao central da camada.
        # Sem multiLine: os CSVs sao CRLF com header, e multiLine ligado e a
        # causa numero um de contagem errada.
        .option("header", True)
        .option("inferSchema", False)
        .csv(caminho)
        # _metadata.file_path e o caminho real do arquivo lido, nao uma string
        # chumbada: se um dia a leitura virar varios arquivos, continua correto.
        .withColumn("_arquivo_origem", col("_metadata.file_path"))
        .withColumn("_ingerido_em", current_timestamp())
    )

    (
        df.write.mode("overwrite")
        .option("overwriteSchema", "true")
        .saveAsTable(destino)
    )

    spark.sql(
        f"COMMENT ON TABLE {destino} IS "
        f"'Bronze - origem: {NOME_DO_SISTEMA[sistema]}, arquivo {sistema}/{tabela}.csv. "
        "Texto puro, sem limpeza nem conversao de tipo.'"
    )

    return spark.table(destino).count()

# COMMAND ----------

# O contrato com a tarefa anterior: a conferencia registrou quantas linhas de
# dado cada arquivo tinha. A bronze tem que reproduzir exatamente esse numero.
esperado = {
    linha["arquivo"]: linha["linhas"]
    for linha in spark.table(controle).select("arquivo", "linhas").collect()
}

resultados = []
for sistema, tabelas in ORIGEM.items():
    for tabela in tabelas:
        linhas = ingerir(sistema, tabela)
        resultados.append((sistema, tabela, linhas, esperado.get(f"{tabela}.csv")))
        print(f"  {sistema}/{tabela}: {linhas:,} linhas")

# COMMAND ----------

# Relatorio -- e o que a turma ve na saida do job.
larg = max(len(t) for _, t, _, _ in resultados)
print(f"{'SISTEMA':<8} {'TABELA':<{larg}} {'NA TABELA':>11} {'NO ARQUIVO':>11}  BATE")
print("-" * (8 + larg + 11 + 11 + 9))

divergentes = []
for sistema, tabela, linhas, no_arquivo in sorted(resultados, key=lambda r: -r[2]):
    bate = linhas == no_arquivo
    if not bate:
        divergentes.append(f"{tabela}: bronze tem {linhas:,}, o arquivo tinha {no_arquivo:,}")
    print(
        f"{sistema:<8} {tabela:<{larg}} {linhas:>11,} "
        f"{(no_arquivo if no_arquivo is not None else -1):>11,}  {'sim' if bate else 'NAO'}"
    )

print("-" * (8 + larg + 11 + 11 + 9))
print(f"{'TOTAL':<8} {len(resultados):<{larg}} {sum(r[2] for r in resultados):>11,}")

# COMMAND ----------

# Se uma contagem divergir, o CSV foi lido errado -- e e muito melhor descobrir
# agora do que na silver, onde o numero ja vai estar dentro de uma soma.
if divergentes:
    raise Exception(
        "Ingestao da bronze FALHOU -- a contagem nao bate com bronze._raw_arquivos:\n  "
        + "\n  ".join(divergentes)
        + "\n\nQuase sempre e multiLine ligado ou separador trocado na leitura do CSV."
    )

print(f"OK: {len(resultados)} tabelas na bronze, {sum(r[2] for r in resultados):,} linhas, "
      "iguais ao que chegou no Volume.")
