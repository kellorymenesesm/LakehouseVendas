-- =====================================================================
-- SILVER . PRODUTOS e ITENS_PEDIDO
--
-- A DECISAO DA NOITE esta aqui: 2.327 itens tem quantidade negativa.
-- Nao e erro de digitacao, e DEVOLUCAO. Tres caminhos possiveis:
--
--   1. descartar     -> o faturamento INFLA em R$ 1.308.266,49
--   2. manter sem flag -> toda soma da empresa fica poluida
--   3. manter COM flag -> preserva os dois numeros
--
-- O terceiro e o unico que nao decide pelo analista. E o que esta feito
-- aqui: a linha fica, e a coluna devolucao diz o que ela e.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.produtos
COMMENT 'Catalogo de produtos, tipado. 30 SKUs estao inativos - o que importa e que os pedidos antigos deles continuam existindo.'
AS
SELECT
  sku,
  descricao,
  categoria,
  marca,
  nota_olfativa,
  CAST(preco_tabela AS DECIMAL(18,2)) AS preco_tabela,
  CAST(custo_unitario AS DECIMAL(18,2)) AS custo_unitario,
  unidade,
  CASE WHEN ativo = 'S' THEN true ELSE false END AS ativo,
  try_to_date(data_lancamento) AS data_lancamento,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.produtos) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.produtos;

ALTER TABLE lakehouse_rotaperfume.silver.produtos ALTER COLUMN data_lancamento
  COMMENT 'Nula para 245 produtos na origem. try_to_date preserva a nulidade em vez de abortar.';

-- ---------------------------------------------------------------------

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.itens_pedido
COMMENT 'Itens de pedido. NENHUMA linha foi descartada: as 2.327 devolucoes ficam, sinalizadas por devolucao, para que a analise escolha entre o bruto e o liquido.'
AS
SELECT
  CAST(i.item_id AS INT) AS item_id,
  CAST(i.pedido_id AS INT) AS pedido_id,
  i.sku,
  CAST(i.quantidade AS INT) AS quantidade,
  -- quantidade negativa e devolucao, nao erro
  CASE WHEN CAST(i.quantidade AS INT) < 0 THEN true ELSE false END AS devolucao,
  abs(CAST(i.quantidade AS INT)) AS quantidade_abs,
  CAST(i.preco_praticado AS DECIMAL(18,2)) AS preco_praticado,
  CAST(i.desconto_pct AS DECIMAL(9,4)) AS desconto_pct,
  CAST(i.valor_bruto AS DECIMAL(18,2)) AS valor_bruto,
  -- expoe o item vendido de produto que saiu de linha (76 itens)
  CASE WHEN p.ativo = 'N' THEN true ELSE false END AS sku_descontinuado,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.itens_pedido) AS _linhas_origem
FROM lakehouse_rotaperfume.bronze.itens_pedido i
LEFT JOIN lakehouse_rotaperfume.bronze.produtos p
  ON p.sku = i.sku;

ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN devolucao
  COMMENT 'Verdadeiro quando a quantidade veio negativa na origem (2.327 itens). Devolucao, nao erro: descartar essas linhas inflaria o faturamento em mais de um milhao de reais.';
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN quantidade_abs
  COMMENT 'Quantidade em modulo, para contagem de volume. O sinal fica preservado em quantidade.';
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido ALTER COLUMN sku_descontinuado
  COMMENT 'Item vendido de produto hoje inativo (76 itens). Exposto, nao corrigido - a venda aconteceu.';

-- =====================================================================
-- O CONTRATO
-- =====================================================================
ALTER TABLE lakehouse_rotaperfume.silver.itens_pedido
  ADD CONSTRAINT quantidade_abs_positiva CHECK (quantidade_abs > 0);
