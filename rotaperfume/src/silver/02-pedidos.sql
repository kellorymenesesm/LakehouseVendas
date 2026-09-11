-- =====================================================================
-- SILVER . PEDIDOS
--
-- 3.443 datas vem em dd/MM/yyyy misturadas com ISO no mesmo campo.
-- 957 pedidos cancelados chegam com valor zerado e NENHUMA flag: quem
-- olha a tabela nao tem como saber que aquele zero e cancelamento.
--
-- E a armadilha da constraint: a regra intuitiva seria valor_liquido >= 0,
-- e ela FALHA em 135 pedidos. Nao e sujeira - sao pedidos com item
-- devolvido, cujo saldo virou negativo. Negocio legitimo.
-- A regra certa e a que esta no fim deste arquivo.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.pedidos
COMMENT 'Pedidos limpos e tipados. Cancelamento vira flag explicita e valor_liquido separa o que entrou de fato do que so foi registrado.'
AS
WITH base AS (
  SELECT
    CAST(pedido_id AS INT) AS pedido_id,
    CAST(cliente_id AS INT) AS cliente_id,
    CAST(vendedor_id AS INT) AS vendedor_id,
    coalesce(try_to_date(data_pedido),
             try_to_date(data_pedido, 'dd/MM/yyyy')) AS data_pedido,
    canal,
    status,
    CAST(valor_total AS DECIMAL(18,2)) AS valor_total,
    CASE WHEN status = 'Cancelado' THEN true ELSE false END AS cancelado
  FROM lakehouse_rotaperfume.bronze.pedidos
)
SELECT
  pedido_id,
  cliente_id,
  vendedor_id,
  data_pedido,
  canal,
  status,
  valor_total,
  cancelado,
  -- o numero que se soma. Cancelado nao entra no faturamento, mas a
  -- LINHA continua aqui: apagar pedido cancelado esconde a operacao.
  CASE WHEN cancelado THEN CAST(0 AS DECIMAL(18,2)) ELSE valor_total END AS valor_liquido,
  year(data_pedido) AS ano,
  month(data_pedido) AS mes,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.pedidos) AS _linhas_origem
FROM base;

ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN data_pedido
  COMMENT 'Origem mistura ISO e dd/MM/yyyy (3.443 linhas no formato BR). Convertida por coalesce de dois try_to_date - to_date abortaria a query em ANSI mode.';
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN cancelado
  COMMENT 'Derivada de status = Cancelado. Na origem o cancelamento so aparecia como valor zerado, sem flag.';
ALTER TABLE lakehouse_rotaperfume.silver.pedidos ALTER COLUMN valor_liquido
  COMMENT 'Zero quando cancelado, valor_total caso contrario. E a coluna que se soma para faturamento.';

-- =====================================================================
-- O CONTRATO
-- =====================================================================
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT data_pedido_obrigatoria CHECK (data_pedido IS NOT NULL);

-- NAO use valor_liquido >= 0 aqui: 135 pedidos com devolucao tem saldo
-- negativo legitimo e a constraint seria recusada na criacao.
ALTER TABLE lakehouse_rotaperfume.silver.pedidos
  ADD CONSTRAINT pedido_cancelado_zerado CHECK (NOT cancelado OR valor_liquido = 0);
