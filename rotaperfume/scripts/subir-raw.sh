#!/usr/bin/env bash
#
# Sobe os 10 CSVs de dados/erp e dados/crm para o Volume raw do Unity Catalog.
# Rode DEPOIS do `bundle deploy` -- o Volume precisa existir antes.
set -euo pipefail

PROFILE="${1:-}"
CATALOG="${2:-lakehouse_rotaperfume}"

if [ -z "$PROFILE" ]; then
  echo "uso: bash scripts/subir-raw.sh <profile> [catalogo]" >&2
  echo "     o profile nao tem default de proposito -- sempre explicito." >&2
  exit 1
fi

# Trabalha a partir da raiz do bundle, com caminhos RELATIVOS: no Git Bash do
# Windows um caminho absoluto estilo /c/Users/... nao chega inteiro no
# databricks.exe, que e binario nativo.
cd "$(dirname "$0")/.."

# dados/ fica dois niveis acima: esta fora do repositorio git, que comeca em
# LakehouseVendas/. Os CSVs sao material local, nao versionado.
DADOS="../../dados"

if [ ! -d "$DADOS/erp" ] || [ ! -d "$DADOS/crm" ]; then
  echo "ERRO: nao achei os CSVs em ${DADOS} (relativo a $(pwd))" >&2
  echo "      esperado: dados/erp (5 arquivos) e dados/crm (5 arquivos)" >&2
  exit 1
fi

DESTINO="dbfs:/Volumes/${CATALOG}/bronze/raw"

# O destino exige o esquema `dbfs:` mesmo sendo Volume do Unity Catalog --
# sem ele o `fs cp` reclama do caminho.
for SISTEMA in erp crm; do
  echo ">> subindo $SISTEMA -> ${DESTINO}/${SISTEMA}"
  databricks fs cp --recursive --overwrite \
    "${DADOS}/${SISTEMA}" "${DESTINO}/${SISTEMA}" \
    --profile "$PROFILE"
done

echo ">> pronto. o que chegou:"
for SISTEMA in erp crm; do
  echo "--- $SISTEMA"
  databricks fs ls "${DESTINO}/${SISTEMA}" --profile "$PROFILE"
done
