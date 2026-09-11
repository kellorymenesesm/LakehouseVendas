#!/usr/bin/env bash
#
# Roda UMA tarefa do rotaperfume_pipeline, em vez do job inteiro.
#
# Por que existe: cada tarefa serverless paga o proprio tempo de partida, e o
# job inteiro paga esse tempo uma vez por tarefa. Ao vivo, testar uma tarefa
# nova pelo job completo e a diferenca entre a sala esperar tres minutos e meio
# a cada tentativa, ou trinta segundos.
#
# O job completo continua valendo -- UMA vez, no fim, para mostrar o DAG
# inteiro verde. Nao como forma de testar.
#
#   bash scripts/rodar-tarefa.sh <profile> <task_key>
#
set -euo pipefail

PROFILE="${1:-}"
TAREFA="${2:-}"

if [ -z "$PROFILE" ] || [ -z "$TAREFA" ]; then
  echo "uso: bash scripts/rodar-tarefa.sh <profile> <task_key>" >&2
  echo "     ex.: bash scripts/rodar-tarefa.sh projetovendas ml_features" >&2
  echo "     o profile nao tem default de proposito -- sempre explicito." >&2
  exit 1
fi

# Caminhos relativos a raiz do bundle: no Git Bash do Windows um caminho
# absoluto estilo /c/Users/... nao chega inteiro no databricks.exe.
cd "$(dirname "$0")/.."

# O id do job sai do proprio bundle -- nao fica chumbado aqui, senao um
# `bundle destroy` seguido de deploy deixaria o script apontando para o nada.
JOB_ID="$(databricks bundle summary --target dev --profile "$PROFILE" --output json \
  | grep -o '"id": *"[0-9]*"' | head -1 | grep -o '[0-9]*')"

if [ -z "$JOB_ID" ]; then
  echo "nao achei o id do rotaperfume_pipeline -- o bundle ja foi deployado?" >&2
  exit 1
fi

echo "job ....: $JOB_ID"
echo "tarefa .: $TAREFA"
echo

# `only` e o parametro do run-now que roda so as task_keys pedidas, ignorando
# o depends_on. E ele que faz a tarefa nova rodar sem as dez anteriores.
#
# ARMADILHA DA CLI: com --json nao se passa o job_id como argumento posicional
# ("no positional arguments are allowed"). O id vai DENTRO do JSON.
databricks jobs run-now --profile "$PROFILE" \
  --json "{\"job_id\": $JOB_ID, \"only\": [\"$TAREFA\"]}"
