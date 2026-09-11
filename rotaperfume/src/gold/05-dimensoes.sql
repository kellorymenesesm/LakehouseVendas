-- =====================================================================
-- GOLD . DIMENSOES CONFORMADAS
--
-- "Conformado" nao e enfeite de vocabulario: significa que estas
-- dimensoes servem a TODOS os marts, e por isso os tres somam igual.
-- Le so da silver - nunca da bronze.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_cliente
COMMENT 'Uma linha por cliente, com atributos cadastrais e comportamento de compra ja calculado. Evita que cada analise reinvente o que e cliente inativo.'
AS
WITH compras AS (
  SELECT
    cliente_id,
    MIN(data_pedido) AS primeiro_pedido,
    MAX(data_pedido) AS ultimo_pedido,
    COUNT(*) AS total_pedidos,
    SUM(valor_liquido) AS receita_acumulada
  FROM lakehouse_rotaperfume.silver.pedidos
  WHERE NOT cancelado
  GROUP BY cliente_id
)
SELECT
  c.cliente_id,
  c.cnpj,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  c.data_cadastro,
  c.ativo,
  p.primeiro_pedido,
  p.ultimo_pedido,
  coalesce(p.total_pedidos, 0) AS total_pedidos,
  coalesce(p.receita_acumulada, CAST(0 AS DECIMAL(18,2))) AS receita_acumulada,
  datediff(current_date(), p.ultimo_pedido) AS dias_sem_comprar,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.clientes c
LEFT JOIN compras p ON p.cliente_id = c.cliente_id;

ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN dias_sem_comprar
  COMMENT 'Dias corridos entre hoje e o ultimo pedido nao cancelado do cliente. Nulo para quem nunca comprou - ausencia de compra nao e zero dia sem comprar.';
ALTER TABLE lakehouse_rotaperfume.gold.dim_cliente ALTER COLUMN receita_acumulada
  COMMENT 'Soma de todos os pedidos nao cancelados do cliente no periodo. Nao desconta devolucao de item.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_produto
COMMENT 'Uma linha por SKU, com atributos comerciais e de custo. E aqui que mora o custo_unitario que define a margem da empresa inteira.'
AS
SELECT
  sku,
  descricao,
  marca,
  categoria,
  nota_olfativa,
  unidade,
  preco_tabela,
  custo_unitario,
  data_lancamento,
  NOT ativo AS descontinuado,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.produtos;

ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN descontinuado
  COMMENT 'Produto que saiu de linha. As vendas passadas dele continuam valendo - descontinuado nao apaga historico.';
ALTER TABLE lakehouse_rotaperfume.gold.dim_produto ALTER COLUMN custo_unitario
  COMMENT 'Custo de aquisicao por unidade. Base do calculo de margem. Nao inclui frete nem impostos.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_vendedor
COMMENT 'Uma linha por vendedor, com regiao e meta. A meta e mensal e serve de denominador do atingimento no mart comercial.'
AS
SELECT
  vendedor_id,
  nome,
  regiao,
  uf,
  data_admissao,
  data_desligamento,
  meta_mensal,
  ativo,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.vendedores;

ALTER TABLE lakehouse_rotaperfume.gold.dim_vendedor ALTER COLUMN meta_mensal
  COMMENT 'Meta de receita por mes, em reais. Vale para todos os meses do periodo - nao ha historico de meta na origem.';

-- ---------------------------------------------------------------------
-- O calendario nasce do proprio dado: do primeiro dia do mes do primeiro
-- pedido ate o ultimo dia do mes do ultimo pedido. Sem data chumbada,
-- entao ele acompanha o dataset se ele crescer.
-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.dim_calendario
COMMENT 'Um dia por linha cobrindo todo o periodo de pedidos (24 meses). Traz o nome do mes em portugues e marca os meses de pico do setor.'
AS
WITH periodo AS (
  SELECT
    CAST(date_trunc('month', MIN(data_pedido)) AS DATE) AS inicio,
    last_day(MAX(data_pedido)) AS fim
  FROM lakehouse_rotaperfume.silver.pedidos
),
dias AS (
  SELECT explode(sequence(inicio, fim, INTERVAL 1 DAY)) AS dia FROM periodo
)
SELECT
  dia,
  year(dia) AS ano,
  month(dia) AS mes,
  CASE month(dia)
    WHEN 1 THEN 'Janeiro'   WHEN 2 THEN 'Fevereiro' WHEN 3 THEN 'Marco'
    WHEN 4 THEN 'Abril'     WHEN 5 THEN 'Maio'      WHEN 6 THEN 'Junho'
    WHEN 7 THEN 'Julho'     WHEN 8 THEN 'Agosto'    WHEN 9 THEN 'Setembro'
    WHEN 10 THEN 'Outubro'  WHEN 11 THEN 'Novembro' WHEN 12 THEN 'Dezembro'
  END AS nome_mes,
  quarter(dia) AS trimestre,
  CASE dayofweek(dia)
    WHEN 1 THEN 'Domingo' WHEN 2 THEN 'Segunda' WHEN 3 THEN 'Terca'
    WHEN 4 THEN 'Quarta'  WHEN 5 THEN 'Quinta'  WHEN 6 THEN 'Sexta'
    WHEN 7 THEN 'Sabado'
  END AS dia_semana,
  dayofweek(dia) IN (1, 7) AS fim_de_semana,
  month(dia) IN (4, 6, 10) AS mes_pico_setor,
  current_timestamp() AS _processado_em
FROM dias;

ALTER TABLE lakehouse_rotaperfume.gold.dim_calendario ALTER COLUMN mes_pico_setor
  COMMENT 'Abril, junho e outubro - os meses de pico da perfumaria no atacado (reposicao pre-dia das maes, festa junina e pre-natal). A sazonalidade do setor e invertida em relacao ao varejo: outubro e o topo, janeiro o vale.';
