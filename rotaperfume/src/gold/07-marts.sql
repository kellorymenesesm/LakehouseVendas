-- =====================================================================
-- GOLD . MARTS
--
-- Um mart por diretoria. O erro classico e criar fato_vendas_comercial
-- e fato_vendas_produto: em tres meses eles divergem e ninguem sabe
-- qual esta certo. O que separa um mart do outro e a DIMENSAO DOMINANTE
-- e as METRICAS - nunca a tabela base.
--
-- Os dois primeiros saem do MESMO fato_vendas e somam o MESMO
-- R$ 102.303.828,05. E isso que a palavra "conformado" significa.
--
-- Divisao sempre por try_divide: em ANSI mode, x/0 nao devolve nulo,
-- aborta a query.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor
COMMENT 'Mart da diretoria comercial. Grao: vendedor x mes. Responde atingimento de meta, carteira atendida e ticket medio sem ninguem precisar lembrar da regra de pedido cancelado.'
AS
SELECT
  f.vendedor_id,
  v.nome AS vendedor,
  v.regiao,
  f.ano,
  f.mes,
  SUM(f.receita) AS receita,
  SUM(f.margem) AS margem,
  v.meta_mensal AS meta,
  ROUND(100 * try_divide(SUM(f.receita), v.meta_mensal), 1) AS atingimento_pct,
  COUNT(DISTINCT f.cliente_id) AS clientes_atendidos,
  COUNT(DISTINCT f.pedido_id) AS pedidos,
  ROUND(try_divide(SUM(f.receita), COUNT(DISTINCT f.pedido_id)), 2) AS ticket_medio
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.gold.dim_vendedor v ON v.vendedor_id = f.vendedor_id
GROUP BY f.vendedor_id, v.nome, v.regiao, f.ano, f.mes, v.meta_mensal;

ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN atingimento_pct
  COMMENT 'Receita do mes dividida pela meta mensal, em percentual. A meta e a mesma para todos os meses - a origem nao guarda historico de meta.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN ticket_medio
  COMMENT 'Receita dividida pelo numero de PEDIDOS distintos do mes, nao pelo numero de itens.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_vendas_por_vendedor ALTER COLUMN receita
  COMMENT 'Receita liquida, ja com as devolucoes descontadas. A soma da coluna inteira fecha com a silver.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_produto_performance
COMMENT 'Mart da diretoria de produto. Grao: SKU x mes. Traz margem percentual e a classe ABC do SKU dentro de cada mes.'
AS
WITH base AS (
  SELECT
    f.ano,
    f.mes,
    f.sku,
    p.descricao,
    p.marca,
    p.categoria,
    SUM(f.quantidade) AS quantidade,
    SUM(f.receita) AS receita,
    SUM(f.margem) AS margem
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = f.sku
  GROUP BY f.ano, f.mes, f.sku, p.descricao, p.marca, p.categoria
),
ranqueado AS (
  SELECT
    *,
    -- receita acumulada do mes, do SKU que mais vendeu para o que menos vendeu
    SUM(receita) OVER (
      PARTITION BY ano, mes ORDER BY receita DESC
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS receita_acumulada,
    SUM(receita) OVER (PARTITION BY ano, mes) AS receita_do_mes,
    row_number() OVER (PARTITION BY ano, mes ORDER BY receita DESC) AS posicao_no_mes
  FROM base
)
SELECT
  ano,
  mes,
  sku,
  descricao,
  marca,
  categoria,
  quantidade,
  receita,
  margem,
  ROUND(100 * try_divide(margem, receita), 1) AS margem_pct,
  posicao_no_mes,
  CASE
    WHEN try_divide(receita_acumulada, receita_do_mes) <= 0.80 THEN 'A'
    WHEN try_divide(receita_acumulada, receita_do_mes) <= 0.95 THEN 'B'
    ELSE 'C'
  END AS curva_abc
FROM ranqueado;

ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN curva_abc
  COMMENT 'Classe ABC do SKU DENTRO daquele mes: A ate 80% da receita acumulada do mes, B ate 95%, C o restante. A classe e mensal - o mesmo SKU pode ser A num mes e C no outro, e isso e informacao.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_produto_performance ALTER COLUMN margem_pct
  COMMENT 'Margem dividida pela receita, em percentual. Kit Presente fica em torno de 33% e Oleo Concentrado de 50%.';

-- ---------------------------------------------------------------------
-- Este mart e a excecao deliberada: recebimento NAO e um fato de vendas,
-- entao ele le da silver.pagamentos e nao do fato_vendas. Por isso o
-- teste 8 confere o mart de produto contra o fato, e nao este.
-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento
COMMENT 'Mart da diretoria financeira. Grao: mes de VENCIMENTO. Responde quanto ha para receber, quanto entrou, com quantos dias de atraso e quanto se pagou de taxa.'
AS
SELECT
  year(data_vencimento) AS ano_vencimento,
  month(data_vencimento) AS mes_vencimento,
  COUNT(*) AS titulos,
  SUM(valor) AS valor_a_receber,
  SUM(valor) FILTER (WHERE data_pagamento IS NOT NULL) AS recebido,
  SUM(valor) FILTER (WHERE data_pagamento IS NULL) AS em_aberto,
  ROUND(AVG(datediff(data_pagamento, data_vencimento))
        FILTER (WHERE data_pagamento IS NOT NULL), 1) AS atraso_medio_dias,
  SUM(valor - valor_liquido) AS custo_taxa,
  current_timestamp() AS _processado_em
FROM lakehouse_rotaperfume.silver.pagamentos
GROUP BY year(data_vencimento), month(data_vencimento);

ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN atraso_medio_dias
  COMMENT 'Media de dias entre vencimento e pagamento, so dos titulos ja pagos. Negativo significa pagamento antecipado.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN custo_taxa
  COMMENT 'Quanto a empresa deixou na mao do meio de pagamento: valor bruto menos valor liquido do titulo.';
ALTER TABLE lakehouse_rotaperfume.gold.mart_financeiro_recebimento ALTER COLUMN em_aberto
  COMMENT 'Titulos sem data de pagamento. Ausencia de pagamento, nao sujeira de dado.';
