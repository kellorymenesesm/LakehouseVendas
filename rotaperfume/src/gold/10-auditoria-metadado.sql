-- =====================================================================
-- GOLD . AUDITORIA DE METADADO
--
-- Metadado faltando e BUG, nao pendencia de documentacao.
--
-- A partir do momento em que existe um agente lendo COMMENT para decidir
-- qual coluna usar, comentario deixou de ser cortesia com o proximo
-- humano: virou interface. Uma coluna chamada vl_liq sem comentario e
-- uma coluna que o agente vai errar -- e ele vai errar com confianca,
-- devolvendo um numero com cara de numero certo.
--
-- Duas regras, e as duas QUEBRAM o job:
--   1. toda tabela e view da gold precisa de COMMENT na TABELA
--   2. toda coluna de fato_vendas e das 6 views de negocio precisa de
--      COMMENT -- sao os objetos que o Genie le
--
-- No fim, um relatorio de cobertura por objeto que NAO quebra. Ele serve
-- para a conversa com quem vai consumir a gold: mostra onde o metadado
-- ainda esta ralo nas dimensoes, nos marts e nas tabelas de feature, que
-- hoje nao sao data_source do agente.
--
-- Mesma escolha do 08-testes.sql: grava o resultado em tabela ANTES de
-- levantar a excecao. A saida de sql_task no log do job vem VAZIA, entao
-- relatorio que so imprime e relatorio que ninguem le.
-- =====================================================================

-- As 6 views de negocio + o fato. E esta lista que define o contrato:
-- objeto que o agente le tem 100% de cobertura de coluna, sem excecao.
CREATE OR REPLACE TEMPORARY VIEW _objetos_do_agente AS
SELECT * FROM VALUES
  ('fato_vendas'), ('receita_mensal'), ('ranking_marcas'),
  ('margem_por_categoria'), ('clientes_em_risco'), ('efeito_lancamento'),
  ('ruptura_por_marca')
AS t(objeto);

-- ---------------------------------------------------------------------
-- O ACHADO. Uma linha por problema encontrado, com o tipo e o objeto.
-- Tabela vazia = auditoria limpa.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold._auditoria_metadado
COMMENT 'Achados da ultima auditoria de metadado da gold: um registro por objeto ou coluna sem COMMENT. Tabela vazia significa auditoria limpa. Se tiver linha, a tarefa auditoria_de_metadado derrubou o job.'
AS
-- Regra 1 - tabela ou view da gold sem COMMENT na tabela.
SELECT 'TABELA SEM COMMENT'        AS tipo,
       t.table_name                AS objeto,
       CAST(NULL AS STRING)        AS coluna,
       concat(lower(t.table_type), ' da gold sem COMMENT na tabela') AS detalhe
FROM lakehouse_rotaperfume.information_schema.tables t
WHERE t.table_schema = 'gold'
  AND (t.comment IS NULL OR trim(t.comment) = '')

UNION ALL
-- Regra 2 - coluna sem COMMENT nos objetos que o agente le.
SELECT 'COLUNA SEM COMMENT',
       c.table_name,
       c.column_name,
       'coluna de objeto exposto ao Genie sem COMMENT'
FROM lakehouse_rotaperfume.information_schema.columns c
JOIN _objetos_do_agente o
  ON c.table_name = o.objeto
WHERE c.table_schema = 'gold'
  AND (c.comment IS NULL OR trim(c.comment) = '');

-- ---------------------------------------------------------------------
-- O RELATORIO DE COBERTURA. Nao quebra nada: e o retrato honesto de
-- quanto da gold esta documentado, objeto por objeto.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold._cobertura_metadado
COMMENT 'Cobertura de COMMENT por objeto da gold: colunas totais, comentadas e percentual, com a marca de quais objetos sao lidos pelo Genie. Relatorio - nao quebra o job.'
AS
SELECT
  c.table_name                                                                   AS objeto,
  max(t.table_type)                                                              AS tipo,
  (max(t.comment) IS NOT NULL AND trim(max(t.comment)) <> '')                    AS tem_comment_na_tabela,
  count(*)                                                                       AS colunas,
  count(*) FILTER (WHERE c.comment IS NOT NULL AND trim(c.comment) <> '')        AS comentadas,
  round(100.0 * count(*) FILTER (WHERE c.comment IS NOT NULL AND trim(c.comment) <> '') / count(*), 1) AS cobertura_pct,
  max(CASE WHEN o.objeto IS NOT NULL THEN true ELSE false END)                   AS lido_pelo_genie
FROM lakehouse_rotaperfume.information_schema.columns c
JOIN lakehouse_rotaperfume.information_schema.tables t
  ON t.table_schema = c.table_schema AND t.table_name = c.table_name
LEFT JOIN _objetos_do_agente o
  ON c.table_name = o.objeto
WHERE c.table_schema = 'gold'
GROUP BY c.table_name;

-- =====================================================================
-- O DENTE. Enquanto este statement existir, objeto sem metadado nao
-- chega ao agente. E de proposito que ele nomeia TODOS os achados: a
-- correcao vira um prompt so, nao uma rodada por erro.
-- =====================================================================
SELECT CASE
         WHEN COUNT(*) = 0 THEN 'AUDITORIA DE METADADO: 100% DOS OBJETOS DO AGENTE DOCUMENTADOS'
         ELSE raise_error(concat('AUDITORIA DE METADADO FALHOU -- ',
                                 CAST(COUNT(*) AS STRING), ' achado(s): ',
                                 array_join(collect_list(concat(objeto,
                                   coalesce(concat('.', coluna), ''))), ' | ')))
       END AS resultado
FROM lakehouse_rotaperfume.gold._auditoria_metadado;
