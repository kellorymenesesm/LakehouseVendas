-- =====================================================================
-- SILVER . CLIENTES
--
-- Tres formatos de CNPJ na origem (1.111 pontuados, 223 com espaco em
-- volta, 309 com zero a esquerda) e 40 empresas cadastradas duas vezes,
-- com cliente_id diferente em cada cadastro.
--
-- DISTINCT nao resolve: para o banco, as duas linhas SAO diferentes.
-- Quem resolve e normalizar o CNPJ primeiro e so entao deduplicar.
--
-- ANSI mode esta ligado neste workspace: to_date() sobre data malformada
-- ABORTA a query com CAST_INVALID_INPUT. Por isso try_to_date, sempre.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.silver.clientes
COMMENT 'Clientes limpos, tipados e deduplicados por CNPJ (3.040 cadastros na origem para 3.000 empresas). Mantem o cadastro mais antigo de cada CNPJ e guarda os ids descartados em cliente_ids_duplicados.'
AS
WITH normalizado AS (
  SELECT
    CAST(cliente_id AS INT) AS cliente_id,
    -- trim -> so digito -> preenche com zero a esquerda ate 14.
    -- NUNCA converter CNPJ para numero: os 309 com zero a esquerda
    -- perderiam o zero calados.
    lpad(regexp_replace(trim(cnpj), '[^0-9]', ''), 14, '0') AS cnpj,
    initcap(trim(regexp_replace(razao_social, ' +', ' '))) AS razao_social,
    segmento,
    cidade,
    uf,
    bairro,
    -- os dois formatos que existem no campo, na ordem em que sao comuns
    coalesce(try_to_date(data_cadastro),
             try_to_date(data_cadastro, 'dd/MM/yyyy')) AS data_cadastro,
    CASE WHEN ativo = 'S' THEN true ELSE false END AS ativo
  FROM lakehouse_rotaperfume.bronze.clientes
),
ordenado AS (
  SELECT
    *,
    -- o cadastro MAIS ANTIGO vence; cliente_id desempata para o
    -- resultado ser o mesmo em toda execucao
    row_number() OVER (PARTITION BY cnpj ORDER BY data_cadastro ASC, cliente_id ASC) AS ordem,
    collect_list(cliente_id) OVER (PARTITION BY cnpj) AS ids_do_cnpj
  FROM normalizado
)
SELECT
  cliente_id,
  cnpj,
  razao_social,
  segmento,
  cidade,
  uf,
  bairro,
  data_cadastro,
  ativo,
  -- os ids descartados NAO somem: os pedidos antigos ainda apontam para eles
  array_except(ids_do_cnpj, array(cliente_id)) AS cliente_ids_duplicados,
  current_timestamp() AS _processado_em,
  (SELECT COUNT(*) FROM lakehouse_rotaperfume.bronze.clientes) AS _linhas_origem
FROM ordenado
WHERE ordem = 1;

-- COMMENT nas colunas que exigiram decisao de limpeza
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cnpj
  COMMENT 'CNPJ normalizado para 14 digitos: trim, remocao de nao-digito e lpad com zero. Texto, nunca numero - converter apagaria o zero a esquerda de 309 clientes.';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN razao_social
  COMMENT 'Padronizada com initcap e espaco duplo colapsado. Na origem 305 vinham em CAIXA ALTA.';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN data_cadastro
  COMMENT 'Origem mistura ISO e dd/MM/yyyy (347 linhas no formato BR). Convertida por coalesce de dois try_to_date.';
ALTER TABLE lakehouse_rotaperfume.silver.clientes ALTER COLUMN cliente_ids_duplicados
  COMMENT 'Ids de cadastro descartados na deduplicacao deste CNPJ. Vazio quando o cliente so tinha um cadastro. Serve para rastrear pedidos antigos que apontam para o id antigo.';

-- =====================================================================
-- O CONTRATO
-- Nao e comentario: o Delta passa a RECUSAR escrita que viole a regra.
-- A regra vira da tabela, nao do script que rodou hoje.
-- =====================================================================
ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT cnpj_14_digitos CHECK (length(cnpj) = 14);

ALTER TABLE lakehouse_rotaperfume.silver.clientes
  ADD CONSTRAINT data_cadastro_obrigatoria CHECK (data_cadastro IS NOT NULL);
