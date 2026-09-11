#!/usr/bin/env bash
#
# Cria o catalogo do lakehouse. Rode ANTES do primeiro `bundle deploy`: os
# schemas do bundle precisam de um catalogo que ja exista.
#
# POR QUE ISTO NAO ESTA NO BUNDLE
# -------------------------------
# Neste workspace o Default Storage esta ligado, e nessa configuracao a API do
# Unity Catalog RECUSA criar catalogo -- ela exige um MANAGED LOCATION que a
# conta nao tem:
#
#   Error: Metastore storage root URL does not exist.
#          Default Storage is enabled in your account. (400 INVALID_STATE)
#
# O mesmo CREATE CATALOG, rodado como SQL no warehouse, funciona. Entao o
# catalogo nasce aqui e todo o resto (schemas, volume) nasce no bundle.
set -euo pipefail

PROFILE="${1:-}"
CATALOG="${2:-lakehouse_rotaperfume}"
WAREHOUSE="${3:-a5b638ac09d4df5e}"

if [ -z "$PROFILE" ]; then
  echo "uso: bash scripts/criar-catalogo.sh <profile> [catalogo] [warehouse_id]" >&2
  echo "     o profile nao tem default de proposito -- sempre explicito." >&2
  exit 1
fi

echo ">> criando o catalogo '$CATALOG' (profile: $PROFILE)"

databricks experimental aitools tools query \
  "CREATE CATALOG IF NOT EXISTS ${CATALOG}
   COMMENT 'Lakehouse de vendas da rotaperfume - bronze, silver e gold como codigo.'" \
  --warehouse "$WAREHOUSE" \
  --profile "$PROFILE"

echo ">> pronto. conferindo:"
databricks catalogs list --profile "$PROFILE" | grep -E "^Name|${CATALOG}"
