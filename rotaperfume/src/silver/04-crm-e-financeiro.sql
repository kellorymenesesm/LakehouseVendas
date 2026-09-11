-- =====================================================================
-- SILVER . CRM e FINANCEIRO
-- vendedores, carteira, oportunidades, visitas, pagamentos, estoque
--
-- A regra desta secao: quando o dado da origem contradiz a realidade,
-- a silver EXPOE o problema em uma coluna. Nao conserta calada.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.vendedores
COMMENT 'Equipe de vendas, tipada. 6 vendedores estao desligados - e alguns ainda tem carteira vigente (ver silver.carteira).'
AS
SELECT
  CAST(vendedor_id AS INT) AS vendedor_id,
  initcap(trim(regexp_replace(nome, ' +', ' '))) AS nome,
  regiao,
  uf,
  try_to_date(data_admissao) AS data_admissao,
  try_to_date(data_desligamento) AS data_desligamento,
  CAST(meta_mensal AS DECIMAL(18,2)) AS meta_mensal,
  CASE WHEN data_desligamento IS NULL THEN true ELSE false END AS ativo,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.vendedores) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.vendedores;

-- ---------------------------------------------------------------------
-- O caso mais interessante da secao: existe carteira SEM data de fim
-- cujo vendedor ja foi desligado. O dado nao esta errado - o processo
-- e que ficou pela metade. A silver nao inventa uma data_fim: ela cria
-- a coluna que faz o gestor ver as 441 carteiras orfas.
-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.carteira
COMMENT 'Vinculo cliente-vendedor. Expoe em orfao_vendedor_desligado as 441 carteiras que seguem abertas com vendedor ja desligado - problema de processo, nao de dado.'
AS
SELECT
  CAST(c.carteira_id AS INT) AS carteira_id,
  CAST(c.cliente_id AS INT) AS cliente_id,
  CAST(c.vendedor_id AS INT) AS vendedor_id,
  try_to_date(c.data_inicio) AS data_inicio,
  try_to_date(c.data_fim) AS data_fim,
  -- vigente de verdade: sem data_fim E com vendedor ainda na casa
  CASE WHEN c.data_fim IS NULL AND v.data_desligamento IS NULL
       THEN true ELSE false END AS vigente,
  -- o que o gestor precisa ver
  CASE WHEN c.data_fim IS NULL AND v.data_desligamento IS NOT NULL
       THEN true ELSE false END AS orfao_vendedor_desligado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.carteira) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.carteira c
LEFT JOIN lakehouse_rotaperfume.bronze.vendedores v
  ON v.vendedor_id = c.vendedor_id;

ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN vigente
  COMMENT 'Carteira sem data_fim E com vendedor nao desligado. Respeita as duas condicoes de proposito.';
ALTER TABLE lakehouse_rotaperfume.silver.carteira ALTER COLUMN orfao_vendedor_desligado
  COMMENT 'Carteira aberta cujo vendedor ja foi desligado (441 casos). O dado da origem nao foi alterado - o problema foi exposto.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.oportunidades
COMMENT 'Funil de vendas. As etapas fechadas na origem se chamam Fechado ganho e Fechado perdido - nao Ganha e Perdida.'
AS
SELECT
  CAST(oportunidade_id AS INT) AS oportunidade_id,
  CAST(cliente_id AS INT) AS cliente_id,
  CAST(vendedor_id AS INT) AS vendedor_id,
  origem,
  try_to_date(data_abertura) AS data_abertura,
  etapa,
  -- os valores reais da origem, conferidos com SELECT DISTINCT etapa
  CASE WHEN etapa = 'Fechado ganho'   THEN true ELSE false END AS ganha,
  CASE WHEN etapa = 'Fechado perdido' THEN true ELSE false END AS perdida,
  CASE WHEN etapa IN ('Fechado ganho', 'Fechado perdido')
       THEN false ELSE true END AS em_aberto,
  CAST(probabilidade_pct AS INT) AS probabilidade_pct,
  CAST(valor_estimado AS DECIMAL(18,2)) AS valor_estimado,
  try_to_date(data_fechamento) AS data_fechamento,
  CAST(ciclo_dias AS INT) AS ciclo_dias,
  motivo_perda,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.oportunidades) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.oportunidades;

ALTER TABLE lakehouse_rotaperfume.silver.oportunidades ALTER COLUMN ganha
  COMMENT 'Derivada de etapa = Fechado ganho. Escrever Ganha aqui daria zero em toda linha - confira sempre os valores reais antes do CASE.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.visitas
COMMENT 'Visitas comerciais, tipadas.'
AS
SELECT
  CAST(visita_id AS INT) AS visita_id,
  CAST(cliente_id AS INT) AS cliente_id,
  CAST(vendedor_id AS INT) AS vendedor_id,
  try_to_date(data_visita) AS data_visita,
  resultado,
  CAST(duracao_min AS INT) AS duracao_min,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.visitas) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.visitas;

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pagamentos
COMMENT 'Pagamentos, tipados. data_pagamento nula em 1.865 registros - e o que ainda nao foi pago, nao e sujeira.'
AS
SELECT
  CAST(pagamento_id AS INT) AS pagamento_id,
  CAST(pedido_id AS INT) AS pedido_id,
  forma_pagamento,
  CAST(parcelas AS INT) AS parcelas,
  CAST(valor AS DECIMAL(18,2)) AS valor,
  CAST(taxa_pct AS DECIMAL(9,4)) AS taxa_pct,
  CAST(valor_liquido AS DECIMAL(18,2)) AS valor_liquido,
  try_to_date(data_vencimento) AS data_vencimento,
  try_to_date(data_pagamento) AS data_pagamento,
  status_pagamento,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pagamentos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.pagamentos;

ALTER TABLE lakehouse_rotaperfume.silver.pagamentos ALTER COLUMN data_pagamento
  COMMENT 'Nula quando ainda nao houve pagamento (1.865 registros). Ausencia com significado, preservada.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.estoque
COMMENT 'Snapshot diario de estoque. ruptura e derivada de saldo = 0 e coincide 100% com a flag da origem.'
AS
SELECT
  try_to_date(data_snapshot) AS data_snapshot,
  sku,
  CAST(saldo AS INT) AS saldo,
  CASE WHEN CAST(saldo AS INT) = 0 THEN true ELSE false END AS ruptura,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.estoque) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.estoque;

ALTER TABLE lakehouse_rotaperfume.silver.estoque ALTER COLUMN ruptura
  COMMENT 'Derivada de saldo = 0. Confere com a flag S/N da origem nas 8.400 linhas - a derivacao nao contradiz o ERP.';
