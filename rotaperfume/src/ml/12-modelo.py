# Databricks notebook source
# MAGIC %md
# MAGIC # O modelo de propensao -- e a regua que ele precisa superar
# MAGIC
# MAGIC A ordem deste notebook nao e estetica: **o baseline vem antes do
# MAGIC treino**, de proposito.
# MAGIC
# MAGIC "AUC 0,88" nao quer dizer nada sozinho. "Ganha do que a gente ja fazia de
# MAGIC graca" quer dizer tudo. Se o modelo nao superar as regras simples que
# MAGIC qualquer um escreveria em cinco minutos, o projeto nao se paga -- e e
# MAGIC melhor descobrir isso na primeira celula do que na reuniao.
# MAGIC
# MAGIC Duas metricas, para duas plateias:
# MAGIC
# MAGIC - **`auc`** -- metrica de quem treina.
# MAGIC - **`lift_top200`** -- metrica de quem decide: *dos 200 que a gente ligar,
# MAGIC   quantos compram?* E essa que paga a conta.
# MAGIC
# MAGIC E um teste que **quebra o job se o resultado ficar bom demais**. Vazamento
# MAGIC nao chega com erro: chega com elogio.

# COMMAND ----------

dbutils.widgets.text("catalog", "lakehouse_rotaperfume", "Catalogo")

catalog = dbutils.widgets.get("catalog")

MODELO_UC = f"{catalog}.gold.propensao_compra"
ALVO = "comprou_em_7d"
SEMENTE = 42          # tudo que sorteia neste arquivo usa esta semente
FATIA_HOLDOUT = 0.25  # 25% separados antes de qualquer treino
TOP_N = 200           # o tamanho da fila semanal do time comercial
FOLDS = 5

print(f"catalogo ...: {catalog}")
print(f"modelo no UC: {MODELO_UC}")
print(f"fila ........: {TOP_N} clientes por semana")

# COMMAND ----------

import numpy as np
import pandas as pd

treino_pdf = spark.table(f"{catalog}.gold.features_treino").toPandas()

# cliente_id e chave, _referencia e metadado do corte: nenhum dos dois e
# feature. Deixar cliente_id entrar seria dar ao modelo um identificador para
# decorar em vez de um comportamento para aprender.
NAO_FEATURES = ["cliente_id", "_referencia", ALVO]
COLUNAS = [c for c in treino_pdf.columns if c not in NAO_FEATURES]

X = treino_pdf[COLUNAS]
y = treino_pdf[ALVO].astype(int)
taxa_base = float(y.mean())

print(f"clientes ....: {len(X):,}")
print(f"features ....: {len(COLUNAS)}")
print(f"TAXA BASE ...: {100 * taxa_base:.2f}%  -> {round(TOP_N * taxa_base)} de cada {TOP_N} ligacoes as cegas")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. O baseline -- antes de treinar qualquer coisa
# MAGIC
# MAGIC Tres regras que qualquer pessoa da area escreveria sem modelo nenhum,
# MAGIC usadas como se fossem o score. Mais a moeda, que vale 0,5 por definicao.
# MAGIC
# MAGIC O melhor dos tres vira a regua do teste 1.

# COMMAND ----------

from sklearn.metrics import roc_auc_score
from sklearn.model_selection import train_test_split

X_treino, X_holdout, y_treino, y_holdout = train_test_split(
    X, y, test_size=FATIA_HOLDOUT, random_state=SEMENTE, stratify=y
)

# As regras simples, avaliadas no MESMO holdout em que o modelo sera avaliado.
# Comparar baseline numa amostra e modelo em outra nao compara nada.
#
# O sinal de menos em recencia_dias nao e detalhe: a regra e "ligue para quem
# comprou RECENTEMENTE", entao recencia baixa tem que ficar no topo da fila.
REGRAS = {
    "ligue para quem comprou recentemente": -X_holdout["recencia_dias"],
    "ligue para quem compra mais": X_holdout["valor_total"],
    "ligue para quem esta atrasado": X_holdout["atraso_relativo"],
}

# atraso_relativo e NULL para quem tem um pedido so -- roc_auc_score nao aceita
# NaN. Zero e a leitura honesta da regra: sem ritmo medido, nao ha atraso
# nenhum a alegar, e o cliente vai para o fim da fila.
baselines = {nome: float(roc_auc_score(y_holdout, valor.fillna(0))) for nome, valor in REGRAS.items()}
baselines["jogar uma moeda"] = 0.5

melhor_baseline = max((v, k) for k, v in baselines.items() if k != "jogar uma moeda")
print(f"{'A RESPOSTA':<40} {'AUC':>8}")
print("-" * 49)
for nome, valor in sorted(baselines.items(), key=lambda item: item[1]):
    marca = "  <- a regua" if nome == melhor_baseline[1] else ""
    print(f"{nome:<40} {valor:>8.4f}{marca}")
print("-" * 49)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. O treino
# MAGIC
# MAGIC `HistGradientBoostingClassifier` trata NaN **nativamente** -- e por isso
# MAGIC que este notebook nao imputa nada. As features de ritmo sao NULL de
# MAGIC proposito para quem tem um pedido so, e substituir esse NULL por uma media
# MAGIC seria inventar um ritmo que o cliente nunca teve.
# MAGIC
# MAGIC **Nao troque por XGBoost.** Ele treina e registra sem reclamar, e falha ao
# MAGIC ser carregado de volta no serverless por conflito com o scikit-learn 1.6.1
# MAGIC (`__sklearn_tags__`) -- uma tarefa depois, longe daqui.

# COMMAND ----------

from sklearn.ensemble import HistGradientBoostingClassifier

modelo = HistGradientBoostingClassifier(random_state=SEMENTE)
modelo.fit(X_treino, y_treino)

auc = float(roc_auc_score(y_holdout, modelo.predict_proba(X_holdout)[:, 1]))

print(f"AUC do modelo no holdout ...: {auc:.4f}")
print(f"melhor baseline ............: {melhor_baseline[0]:.4f}  ({melhor_baseline[1]})")
print(f"ganho ......................: {auc - melhor_baseline[0]:+.4f}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 3. A metrica que vai para a reuniao
# MAGIC
# MAGIC `lift_top200` sai de score **out-of-fold**, nao do holdout -- e a diferenca
# MAGIC importa. A fila real e de 200 entre 2.815; no holdout de 704 os 200
# MAGIC primeiros seriam 28% da amostra, e o numero sairia otimista.
# MAGIC
# MAGIC Out-of-fold, cada cliente e pontuado por um modelo que **nao o viu no
# MAGIC treino**, e os 200 primeiros sao 200 entre os 2.815 de verdade.

# COMMAND ----------

from sklearn.model_selection import StratifiedKFold, cross_val_predict

dobras = StratifiedKFold(n_splits=FOLDS, shuffle=True, random_state=SEMENTE)
score_oof = cross_val_predict(
    HistGradientBoostingClassifier(random_state=SEMENTE),
    X, y, cv=dobras, method="predict_proba",
)[:, 1]

fila = np.argsort(-score_oof)[:TOP_N]
acertos_top200 = int(y.iloc[fila].sum())
lift_top200 = float((acertos_top200 / TOP_N) / taxa_base)

print(f"{'ESTRATEGIA':<42} {'DOS ' + str(TOP_N) + ', COMPRAM':>18}")
print("-" * 61)
print(f"{'ligar as cegas':<42} {round(TOP_N * taxa_base):>18}")
print(f"{'ligar para os ' + str(TOP_N) + ' de maior score':<42} {acertos_top200:>18}")
print("-" * 61)
print(f"LIFT: {lift_top200:.2f}x")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 4. Importancia por permutacao
# MAGIC
# MAGIC Embaralha uma coluna de cada vez e mede quanto o AUC cai. E a pergunta
# MAGIC "de que o modelo REALMENTE depende" respondida por experimento, e nao
# MAGIC pela importancia interna da arvore, que superestima coluna de muitos
# MAGIC valores distintos.

# COMMAND ----------

from sklearn.inspection import permutation_importance

importancia = permutation_importance(
    modelo, X_holdout, y_holdout,
    scoring="roc_auc", n_repeats=5, random_state=SEMENTE,
)
ranking = (
    pd.DataFrame({"feature": COLUNAS, "queda_no_auc": importancia.importances_mean})
    .sort_values("queda_no_auc", ascending=False)
    .reset_index(drop=True)
)
feature_numero_1 = str(ranking.loc[0, "feature"])

print(f"{'#':<3}{'FEATURE':<26}{'QUEDA NO AUC':>14}")
print("-" * 43)
for i, linha in ranking.head(10).iterrows():
    print(f"{i + 1:<3}{linha['feature']:<26}{linha['queda_no_auc']:>14.4f}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 5. MLflow -- o modelo vira objeto do catalogo
# MAGIC
# MAGIC Nao e um `.pkl` no Drive de alguem que saiu da empresa. Mesmo catalogo das
# MAGIC tabelas, mesmo GRANT, mesma linhagem -- e a pergunta "qual versao esta em
# MAGIC producao, treinada quando e com que dado" tem resposta sem depender da
# MAGIC memoria de ninguem.

# COMMAND ----------

import mlflow
from databricks.sdk import WorkspaceClient
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient

# ARMADILHA MEDIDA: set_experiment NAO cria a pasta pai. Sem o mkdirs o erro e
# "BAD_REQUEST: For input string: None" -- que nao menciona pasta nenhuma.
workspace = WorkspaceClient()
usuario = workspace.current_user.me().user_name
pasta = f"/Users/{usuario}/rotaperfume"
workspace.workspace.mkdirs(pasta)

mlflow.set_experiment(f"{pasta}/propensao-compra")
mlflow.set_registry_uri("databricks-uc")

with mlflow.start_run(run_name=f"propensao-{FOLDS}folds-semente{SEMENTE}") as execucao:
    mlflow.log_params({
        "algoritmo": "HistGradientBoostingClassifier",
        "semente": SEMENTE,
        "features": len(COLUNAS),
        "clientes_treino": len(X),
        "fatia_holdout": FATIA_HOLDOUT,
        "folds_out_of_fold": FOLDS,
        "top_n": TOP_N,
    })
    mlflow.log_metrics({
        "auc": auc,
        "lift_top200": lift_top200,
        "acertos_top200": acertos_top200,
        "taxa_base": taxa_base,
        **{f"baseline_{i}": v for i, v in enumerate(sorted(baselines.values()))},
    })

    # O serverless tem MLflow 2.22: artifact_path=, nunca o name= do MLflow 3.
    info_modelo = mlflow.sklearn.log_model(
        modelo,
        artifact_path="modelo",
        signature=infer_signature(X_holdout, modelo.predict_proba(X_holdout)[:, 1]),
        input_example=X_holdout.head(5),
        registered_model_name=MODELO_UC,
    )

versao = str(info_modelo.registered_model_version)

# O alias e o contrato com quem consome: o prompt 3 carrega @prod, nao a
# versao 7. Trocar o modelo passa a ser mover o alias.
MlflowClient(registry_uri="databricks-uc").set_registered_model_alias(MODELO_UC, "prod", versao)

print(f"registrado: {MODELO_UC} versao {versao}")
print(f"alias .....: @prod -> versao {versao}")
print(f"run .......: {execucao.info.run_id}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 6. Os tres testes que interrompem a tarefa
# MAGIC
# MAGIC O segundo e o mais importante do notebook: **o job quebra se o resultado
# MAGIC ficar bom demais.** E a unica defesa que funciona contra vazamento,
# MAGIC porque vazamento nao chega com erro -- chega com elogio.

# COMMAND ----------

assert auc >= melhor_baseline[0] + 0.05, (
    f"O modelo nao ganhou da regra simples: AUC {auc:.4f} contra {melhor_baseline[0]:.4f} "
    f"de '{melhor_baseline[1]}'. Precisa de pelo menos 0,05 de vantagem -- senao a "
    "empresa faz o mesmo de graca, com um ORDER BY."
)

assert auc < 0.99, (
    f"AUC {auc:.4f}: bom demais e VAZAMENTO, nao competencia. Alguma feature "
    "enxergou dado posterior ao corte. Confira os filtros '< referencia' em "
    "src/ml/11-features.py antes de comemorar."
)

assert lift_top200 >= 2.5, (
    f"lift_top200 {lift_top200:.2f}x abaixo de 2,5x: a fila nao justifica o projeto. "
    f"Ligar as cegas ja converte {100 * taxa_base:.2f}%."
)

print("OS 3 TESTES PASSARAM")
print(f"  ganha do baseline por {auc - melhor_baseline[0]:.4f} de AUC")
print(f"  AUC {auc:.4f} < 0,99 -- sem cara de vazamento")
print(f"  lift {lift_top200:.2f}x >= 2,5x")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 7. O score -- a fila da semana
# MAGIC
# MAGIC Carrega o modelo pelo **alias**, nao pelo numero da versao. E usa
# MAGIC `predict_proba`: `pyfunc.predict` devolveria a CLASSE, e a coluna inteira
# MAGIC viraria zeros e uns -- uma fila sem ordem dentro de cada grupo.

# COMMAND ----------

from pyspark.sql import functions as F

modelo_prod = mlflow.sklearn.load_model(f"models:/{MODELO_UC}@prod")

features_cliente = spark.table(f"{catalog}.gold.features_cliente")
score_pdf = features_cliente.toPandas()

# O corte vem da COLUNA _referencia, nao de uma constante repetida aqui: a
# tabela ja carrega a data do proprio retrato.
referencia_score = features_cliente.select(F.max("_referencia")).collect()[0][0]

# A ordem das colunas vem do MODELO, nunca da tabela: uma coluna nova na gold
# ou um ORDER BY diferente bastaria para pontuar a feature errada em silencio.
colunas_do_modelo = list(modelo_prod.feature_names_in_)
score_pdf["score"] = modelo_prod.predict_proba(score_pdf[colunas_do_modelo])[:, 1]

print(f"clientes pontuados: {len(score_pdf):,}")
print(f"corte ............: {referencia_score}")
print(f"score ............: min {score_pdf['score'].min():.4f} / max {score_pdf['score'].max():.4f}")

# COMMAND ----------

from pyspark.sql.window import Window

score_sdf = (
    spark.createDataFrame(score_pdf[["cliente_id", "score"]])
    .withColumn("cliente_id", F.col("cliente_id").cast("int"))
    .withColumn("score", F.col("score").cast("double"))
)

# A faixa e o score traduzido para quem nao fala probabilidade. NTILE(4) sobre
# o score: quartis do proprio dia, nao um corte fixo que envelhece.
quartis = Window.orderBy(F.col("score"))
score_sdf = (
    score_sdf
    .withColumn("_quartil", F.ntile(4).over(quartis))
    .withColumn(
        "faixa",
        F.when(F.col("_quartil") == 1, "Fria")
         .when(F.col("_quartil") == 2, "Morna")
         .when(F.col("_quartil") == 3, "Quente")
         .otherwise("Muito quente"),
    )
    .drop("_quartil")
    .withColumn("_referencia", F.lit(referencia_score).cast("date"))
    .withColumn("versao_modelo", F.lit(versao))
)

destino_score = f"{catalog}.gold.score_propensao"
score_sdf.write.mode("overwrite").option("overwriteSchema", "true").saveAsTable(destino_score)

spark.sql(
    f"COMMENT ON TABLE {destino_score} IS "
    f"'Propensao de compra nos proximos 7 dias, por cliente, no corte de {referencia_score}. "
    "Uma linha por cliente com o score (probabilidade), a faixa em quartis e a versao do modelo "
    "que gerou a nota. E desta tabela que sai a fila semanal de ligacoes do time comercial.'"
)

print(f"gravado: {destino_score}")

# COMMAND ----------

# MAGIC %md
# MAGIC ## 8. As metricas tambem viram tabela
# MAGIC
# MAGIC O Genie nao le MLflow, e daqui a seis meses ninguem abre a interface de
# MAGIC experimento. O que fica e o que esta em tabela, no mesmo catalogo do
# MAGIC resto -- com COMMENT, como qualquer gold.

# COMMAND ----------

from datetime import datetime, timezone

metricas = spark.createDataFrame(
    [(
        versao, auc, lift_top200, acertos_top200, taxa_base,
        baselines["ligue para quem comprou recentemente"],
        baselines["ligue para quem compra mais"],
        baselines["ligue para quem esta atrasado"],
        feature_numero_1,
        datetime.now(timezone.utc),
    )],
    "versao STRING, auc DOUBLE, lift_top200 DOUBLE, acertos_top200 INT, taxa_base DOUBLE, "
    "auc_baseline_recencia DOUBLE, auc_baseline_valor DOUBLE, auc_baseline_atraso DOUBLE, "
    "feature_numero_1 STRING, _treinado_em TIMESTAMP",
)

destino_metricas = f"{catalog}.gold.modelo_metricas"
# append, nao overwrite: uma linha por TREINO. O historico e que responde
# "esse modelo ainda esta bom?" daqui a seis meses.
metricas.write.mode("append").saveAsTable(destino_metricas)

spark.sql(
    f"COMMENT ON TABLE {destino_metricas} IS "
    "'Uma linha por treino do modelo de propensao: versao registrada no Unity Catalog, AUC, "
    "lift e acertos na fila de 200, a taxa base da epoca, o AUC das tres regras simples usadas "
    "como baseline e a feature mais importante. E o historico que responde se o modelo ainda esta bom.'"
)

print(f"gravado: {destino_metricas}")

# COMMAND ----------

# A calibragem e a prova que o comercial confere sozinho, sem saber o que e
# curva ROC: a taxa de compra tem que SUBIR da faixa fria para a muito quente.
holdout_pdf = X_holdout.copy()
holdout_pdf["comprou"] = y_holdout.values
holdout_pdf["score"] = modelo.predict_proba(X_holdout)[:, 1]
holdout_pdf["faixa"] = pd.qcut(
    holdout_pdf["score"], 4, labels=["Fria", "Morna", "Quente", "Muito quente"]
)

calibragem = (
    holdout_pdf.groupby("faixa", observed=True)
    .agg(clientes=("comprou", "size"), compraram=("comprou", "sum"), score_medio=("score", "mean"))
    .reset_index()
)
calibragem["faixa"] = calibragem["faixa"].astype(str)
calibragem["taxa_de_compra"] = calibragem["compraram"] / calibragem["clientes"]
calibragem = calibragem[["faixa", "clientes", "compraram", "taxa_de_compra", "score_medio"]]

destino_calibragem = f"{catalog}.gold.calibragem_holdout"
(
    spark.createDataFrame(calibragem)
    .write.mode("overwrite").option("overwriteSchema", "true")
    .saveAsTable(destino_calibragem)
)

spark.sql(
    f"COMMENT ON TABLE {destino_calibragem} IS "
    "'Calibragem do modelo de propensao no holdout: por faixa de score, quantos clientes, quantos "
    "compraram de fato e qual o score medio. A taxa de compra tem que SUBIR da faixa Fria para a "
    "Muito quente - e a conferencia do score que nao exige entender curva ROC.'"
)

print(f"gravado: {destino_calibragem}\n")
print(f"{'FAIXA':<14}{'CLIENTES':>10}{'COMPRARAM':>11}{'% QUE COMPROU':>15}")
print("-" * 50)
for _, linha in calibragem.iterrows():
    print(f"{linha['faixa']:<14}{linha['clientes']:>10,}{linha['compraram']:>11,}{100 * linha['taxa_de_compra']:>14.1f}%")
