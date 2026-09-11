-- ============================================================================
-- ML . A FILA DA SEMANA E AS FERRAMENTAS DO AGENTE
--
-- Score nao e decisao. `0,8412` nao e uma acao. Este arquivo e o ultimo metro:
-- o que separa o modelo que roda do modelo que alguem usa.
--
-- A DECISAO DE DESENHO: a fila e GLOBAL, a capacidade e que e por pessoa.
-- Sao 200 ligacoes e 36 vendedores, e a tentacao e dar 5 para cada um porque
-- parece justo. Justo com quem? Se a carteira de um esta quente e a do outro
-- esta fria, a cota igual obriga o primeiro a deixar cliente quente na mesa
-- para o segundo ligar para cliente frio. Por isso: ORDER BY score DESC
-- LIMIT 200, e nunca cota por vendedor.
--
-- A ORDEM DAS OPERACOES E O ERRO MAIS FACIL DE COMETER AQUI:
--   1o  junte a carteira e DESCARTE quem nao e elegivel
--   2o  ORDER BY score DESC LIMIT 200
--   3o  ROW_NUMBER() OVER (PARTITION BY vendedor ORDER BY score DESC)
-- Se o descarte vier DEPOIS do LIMIT, a fila sai com ~172 linhas em vez de
-- 200 -- os vendedores desligados levam junto os clientes deles -- e o teste 1
-- quebra o job. Filtrando antes, sobram 2.393 clientes elegiveis de 2.816 e a
-- fila fecha em 200 exatas, distribuidas em 36 vendedores.
--
-- ARMADILHA DO AMBIENTE: ANSI mode ligado, divisao por zero ABORTA -- toda
-- razao passa por TRY_DIVIDE. E o "hoje" do dataset e 2026-08-31, nunca
-- current_date().
-- ============================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fila_semanal
COMMENT 'As 200 ligacoes da semana, em ordem de prioridade, ja distribuidas por vendedor. Uma linha por contato a fazer, com o motivo escrito em portugues e o produto a oferecer. Sai de gold.score_propensao cruzado com a carteira vigente: a fila e global por score, nao cota por vendedor.'
AS
WITH

-- 1o PASSO -- quem e ELEGIVEL. Antes de qualquer ordenacao.
-- Cliente sem carteira vigente nao tem quem ligue; carteira de vendedor
-- desligado e a sujeira numero 9 da noite 2 cobrando o preco dela.
elegiveis AS (
  SELECT c.cliente_id,
         v.nome AS vendedor
  FROM lakehouse_rotaperfume.silver.carteira c
  JOIN lakehouse_rotaperfume.silver.vendedores v
    ON v.vendedor_id = c.vendedor_id
   AND v.ativo
  WHERE c.vigente
    AND NOT c.orfao_vendedor_desligado
),

-- O corte de "cliente grande": o decil de cima do valor_total entre os
-- elegiveis. Threshold calculado, nao chumbado -- ano que vem o numero muda.
corte_grande AS (
  SELECT PERCENTILE(f.valor_total, 0.9) AS limite
  FROM lakehouse_rotaperfume.gold.features_cliente f
  JOIN elegiveis e ON e.cliente_id = f.cliente_id
),

-- A marca preferida de cada cliente, por receita. Base da sugestao.
marca_preferida AS (
  SELECT cliente_id, marca,
         ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY SUM(receita) DESC, marca) AS posicao
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY cliente_id, marca
),

-- O que ele JA comprou nos ultimos 90 dias: nao se oferece de novo.
comprado_recente AS (
  SELECT DISTINCT cliente_id, sku
  FROM lakehouse_rotaperfume.gold.fato_vendas
  WHERE data_pedido >= DATE_SUB(DATE'2026-08-31', 90)
),

-- Candidatos a sugestao: SKU da marca preferida, ja comprado no historico,
-- mas ausente dos ultimos 90 dias. E o "parou de comprar" no nivel do item.
candidatos AS (
  SELECT f.cliente_id, f.sku, SUM(f.quantidade) AS unidades
  FROM lakehouse_rotaperfume.gold.fato_vendas f
  JOIN marca_preferida m
    ON m.cliente_id = f.cliente_id AND m.marca = f.marca AND m.posicao = 1
  WHERE NOT EXISTS (
    SELECT 1 FROM comprado_recente r
    WHERE r.cliente_id = f.cliente_id AND r.sku = f.sku
  )
  GROUP BY f.cliente_id, f.sku
),

sugestao_do_cliente AS (
  SELECT cliente_id, sku, unidades
  FROM (
    SELECT cliente_id, sku, unidades,
           ROW_NUMBER() OVER (PARTITION BY cliente_id ORDER BY unidades DESC, sku) AS posicao
    FROM candidatos
  )
  WHERE posicao = 1
),

-- silver.estoque e um SNAPSHOT semanal: a tabela inteira tem 8.400 linhas de
-- historico. O saldo de hoje e a foto mais recente de cada SKU, nao a soma.
estoque_atual AS (
  SELECT sku, saldo, ruptura
  FROM (
    SELECT sku, saldo, ruptura,
           ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS posicao
    FROM lakehouse_rotaperfume.silver.estoque
  )
  WHERE posicao = 1
),

-- 2o PASSO -- so agora a fila. LIMIT 200 sobre quem sobrou do filtro.
duzentos AS (
  SELECT s.cliente_id, s.score, s.faixa, s.versao_modelo,
         e.vendedor,
         d.razao_social, d.cidade, d.uf,
         f.ticket_medio, f.valor_total, f.recencia_dias,
         f.intervalo_medio_dias, f.atraso_relativo, f.comprou_lancamento,
         g.sku AS sku_sugerido
  FROM lakehouse_rotaperfume.gold.score_propensao s
  JOIN elegiveis e            ON e.cliente_id = s.cliente_id
  JOIN lakehouse_rotaperfume.gold.features_cliente f ON f.cliente_id = s.cliente_id
  JOIN lakehouse_rotaperfume.gold.dim_cliente d      ON d.cliente_id = s.cliente_id
  LEFT JOIN sugestao_do_cliente g ON g.cliente_id = s.cliente_id
  ORDER BY s.score DESC
  LIMIT 200
)

-- 3o PASSO -- a numeracao POR VENDEDOR, dentro dos 200 que sobraram.
SELECT
  d.vendedor,
  CAST(ROW_NUMBER() OVER (PARTITION BY d.vendedor ORDER BY d.score DESC) AS INT) AS ordem,
  d.cliente_id,
  d.razao_social,
  d.cidade,
  d.uf,
  d.score,
  d.faixa,
  d.ticket_medio,

  -- FORMAT_NUMBER usa separador AMERICANO: 238539 vira '238,539', que em
  -- portugues le como 238 reais e 539 centavos -- erro de mil vezes numa frase
  -- que o vendedor le em voz alta para o cliente. Por isso o REPLACE.
  --
  -- O motivo. A ORDEM DO CASE VAI DO SINAL MAIS RARO PARA O MAIS COMUM, e a
  -- frequencia foi MEDIDA nesta fila, nao adivinhada:
  --
  --   atraso > 3x .......    0 contatos
  --   atraso > 1,5x .....    7
  --   cliente grande ....   67
  --   comprou lancamento   177   <- o mais comum de todos
  --
  -- comprou_lancamento parece um sinal forte e e o mais BANAL da base: 70% dos
  -- clientes compraram algum lancamento. Colocado antes de "cliente grande",
  -- ele engolia 170 dos 200 contatos e a coluna motivo virava enfeite --
  -- todo vendedor lendo a mesma frase, que e o mesmo que nao ler nenhuma.
  CASE
    WHEN d.atraso_relativo > 3 THEN CONCAT(
      'Compra a cada ', REPLACE(FORMAT_NUMBER(d.intervalo_medio_dias, 0), ',', '.'),
      ' dias e esta ha ', REPLACE(FORMAT_NUMBER(d.recencia_dias, 0), ',', '.'),
      ' sem pedido. Risco de perder para o concorrente.')
    WHEN d.atraso_relativo > 1.5 THEN CONCAT(
      'Esta ', REPLACE(FORMAT_NUMBER(d.atraso_relativo, 1), '.', ','),
      ' vezes mais atrasado que o ritmo dele.')
    WHEN d.valor_total >= (SELECT limite FROM corte_grande) THEN CONCAT(
      'Cliente grande, R$ ', REPLACE(FORMAT_NUMBER(d.valor_total, 0), ',', '.'),
      ' no periodo. Manter proximo.')
    WHEN d.comprou_lancamento = 1 THEN
      'Comprou lancamento recente. Alta chance de repetir.'
    -- O ELSE e OBRIGATORIO: motivo nulo quebra o teste 2, e com razao --
    -- linha sem motivo e linha que o vendedor ignora.
    ELSE 'Dentro do ritmo. Contato de manutencao.'
  END AS motivo,

  CASE
    WHEN d.sku_sugerido IS NULL THEN 'Sem sugestao: ele comprou tudo da marca preferida nos ultimos 90 dias.'
    WHEN e.ruptura OR COALESCE(e.saldo, 0) <= 0 THEN CONCAT(
      p.descricao, ' (', d.sku_sugerido, ') - SEM ESTOQUE, nao prometa prazo.')
    ELSE CONCAT(
      p.descricao, ' (', d.sku_sugerido, ') - ',
      REPLACE(FORMAT_NUMBER(e.saldo, 0), ',', '.'), ' em estoque.')
  END AS sugestao,

  d.versao_modelo,
  DATE'2026-08-31' AS _referencia
FROM duzentos d
LEFT JOIN estoque_atual e                            ON e.sku = d.sku_sugerido
LEFT JOIN lakehouse_rotaperfume.gold.dim_produto p   ON p.sku = d.sku_sugerido;

-- ----------------------------------------------------------------------------
-- COMMENT em TODA coluna. Nao e documentacao: e o que o Genie le para
-- responder "por que este cliente esta no topo da minha lista" sem inventar.
-- ----------------------------------------------------------------------------
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN vendedor
  COMMENT 'Nome do vendedor responsavel pela carteira deste cliente. So vendedor ATIVO aparece aqui.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ordem
  COMMENT 'Posicao do contato dentro da fila DESTE vendedor, sendo 1 o primeiro a ligar. A fila e global por score: um vendedor pode ter 12 contatos e outro apenas 1.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cliente_id
  COMMENT 'Identificador do cliente a contatar.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN razao_social
  COMMENT 'Nome da empresa cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN cidade
  COMMENT 'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN uf
  COMMENT 'Unidade federativa do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN score
  COMMENT 'Probabilidade estimada de o cliente fazer pedido nos proximos 7 dias, de 0 a 1. Sai do modelo gold.propensao_compra. Nao e garantia: e ordenacao.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN faixa
  COMMENT 'O score traduzido em quartis: Fria, Morna, Quente ou Muito quente. A fila semanal e quase toda Muito quente, por construcao.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN ticket_medio
  COMMENT 'Quanto o cliente gasta por pedido, em reais, no historico ate o corte.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN motivo
  COMMENT 'Por que ESTE cliente entrou na fila, em portugues e com os numeros dele dentro. E o que faz o vendedor confiar quando o modelo acerta e entender quando erra, em vez de parar de usar.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN sugestao
  COMMENT 'O que oferecer: o produto mais comprado pelo cliente na marca preferida dele que ele parou de comprar nos ultimos 90 dias, com o saldo do snapshot de estoque mais recente.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN versao_modelo
  COMMENT 'Versao do modelo gold.propensao_compra no Unity Catalog que gerou o score desta linha.';
ALTER TABLE lakehouse_rotaperfume.gold.fila_semanal ALTER COLUMN _referencia
  COMMENT 'Data de corte usada para montar a fila. O hoje deste dataset e 2026-08-31.';

-- ============================================================================
-- AS QUATRO FERRAMENTAS DO AGENTE
--
-- Nao e endpoint, nao e framework e nao tem prompt nenhum: e funcao no
-- catalogo, com contrato e COMMENT. O agente so sabe chamar -- e e o COMMENT
-- que diz a ele QUANDO chamar cada uma.
--
-- ARMADILHA: todo parametro leva prefixo p_. Parametro com o mesmo nome de
-- uma coluna fica ambiguo dentro do corpo e o CREATE falha.
-- ARMADILHA: `LIMIT p_quantos` da INVALID_LIMIT_LIKE_EXPRESSION -- o
-- Databricks exige LIMIT constante. Por isso filtramos por `ordem <=`, que a
-- fila ja vem numerada.
-- ============================================================================

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.priorizar_carteira(
  p_vendedor STRING COMMENT 'Nome do vendedor, como aparece na coluna vendedor de gold.fila_semanal.',
  p_quantos INT COMMENT 'Quantos contatos devolver, a partir do topo da fila dele.'
)
RETURNS TABLE (
  ordem INT,
  cliente_id INT,
  razao_social STRING,
  cidade STRING,
  score DOUBLE,
  faixa STRING,
  motivo STRING,
  sugestao STRING
)
COMMENT 'Use quando um vendedor perguntar para quem ele deve ligar, ou quando pedirem a lista de prioridade de alguem. Devolve os proximos clientes da fila da semana daquele vendedor, ja em ordem, com o motivo e o produto a oferecer.'
RETURN
  SELECT ordem, cliente_id, razao_social, cidade, score, faixa, motivo, sugestao
  FROM lakehouse_rotaperfume.gold.fila_semanal
  WHERE vendedor = p_vendedor
    AND ordem <= p_quantos
  ORDER BY ordem;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.contexto_cliente(
  p_cliente_id INT COMMENT 'Identificador do cliente.'
)
RETURNS TABLE (
  razao_social STRING,
  cidade STRING,
  uf STRING,
  segmento STRING,
  pedidos BIGINT,
  receita_total DOUBLE,
  ticket_medio DOUBLE,
  ultima_compra DATE,
  dias_sem_comprar INT,
  marcas_preferidas STRING
)
COMMENT 'Use antes de uma ligacao, quando perguntarem quem e um cliente ou qual o historico dele. Devolve o resumo: onde fica, quantos pedidos fez, quanto gasta por pedido, quando comprou pela ultima vez e as tres marcas que ele mais compra.'
RETURN
  -- ARMADILHA MEDIDA: subquery escalar correlacionada NAO pode ficar na lista
  -- de um SELECT agregado -- da SCALAR_SUBQUERY_IS_IN_GROUP_BY_OR_AGGREGATE_
  -- FUNCTION. Os dois lados viram CTE e se encontram num CROSS JOIN de uma
  -- linha por uma linha.
  WITH resumo AS (
    SELECT
      MAX(f.razao_social) AS razao_social,
      MAX(f.cidade) AS cidade,
      MAX(f.uf) AS uf,
      MAX(f.segmento) AS segmento,
      COUNT(DISTINCT f.pedido_id) AS pedidos,
      CAST(SUM(f.receita) AS DOUBLE) AS receita_total,
      CAST(TRY_DIVIDE(SUM(f.receita), COUNT(DISTINCT f.pedido_id)) AS DOUBLE) AS ticket_medio,
      MAX(f.data_pedido) AS ultima_compra,
      DATEDIFF(DATE'2026-08-31', MAX(f.data_pedido)) AS dias_sem_comprar
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    WHERE f.cliente_id = p_cliente_id
  ),
  -- Agregue por MARCA antes de ranquear: o fato esta no grao de ITEM, e
  -- colecionando linha a linha o top 3 sai com marca repetida
  -- ('Dahab, Nadir, Dahab') -- que e pior que nao responder.
  marcas AS (
    SELECT ARRAY_JOIN(
             TRANSFORM(
               SLICE(
                 ARRAY_SORT(
                   COLLECT_LIST(STRUCT(m.receita_marca AS receita_marca, m.marca AS marca)),
                   (a, b) -> CASE WHEN a.receita_marca > b.receita_marca THEN -1
                                  WHEN a.receita_marca < b.receita_marca THEN 1
                                  ELSE 0 END
                 ), 1, 3),
               x -> x.marca
             ), ', ') AS marcas_preferidas
    FROM (
      SELECT marca, SUM(receita) AS receita_marca
      FROM lakehouse_rotaperfume.gold.fato_vendas
      WHERE cliente_id = p_cliente_id
      GROUP BY marca
    ) m
  )
  SELECT r.razao_social, r.cidade, r.uf, r.segmento, r.pedidos,
         r.receita_total, r.ticket_medio, r.ultima_compra, r.dias_sem_comprar,
         m.marcas_preferidas
  FROM resumo r CROSS JOIN marcas m;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.sugerir_produtos(
  p_cliente_id INT COMMENT 'Identificador do cliente.'
)
RETURNS TABLE (
  sku STRING,
  descricao STRING,
  marca STRING,
  categoria STRING,
  unidades_no_historico BIGINT,
  ultima_compra DATE,
  dias_sem_comprar_o_item INT,
  saldo_em_estoque INT,
  em_ruptura BOOLEAN
)
COMMENT 'Use quando perguntarem o que oferecer a um cliente. Devolve os produtos que ele ja comprou mas PAROU de comprar nos ultimos 90 dias, do mais comprado para o menos, com o saldo de estoque atual de cada um. Nao sugira item em ruptura sem avisar.'
RETURN
  WITH historico AS (
    SELECT f.sku,
           SUM(f.quantidade) AS unidades,
           MAX(f.data_pedido) AS ultima
    FROM lakehouse_rotaperfume.gold.fato_vendas f
    WHERE f.cliente_id = p_cliente_id
    GROUP BY f.sku
    HAVING MAX(f.data_pedido) < DATE_SUB(DATE'2026-08-31', 90)
  ),
  estoque_atual AS (
    SELECT sku, saldo, ruptura
    FROM (
      SELECT sku, saldo, ruptura,
             ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS posicao
      FROM lakehouse_rotaperfume.silver.estoque
    )
    WHERE posicao = 1
  )
  SELECT h.sku, p.descricao, p.marca, p.categoria,
         h.unidades, h.ultima,
         DATEDIFF(DATE'2026-08-31', h.ultima),
         e.saldo, e.ruptura
  FROM historico h
  JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = h.sku
  LEFT JOIN estoque_atual e ON e.sku = h.sku
  ORDER BY h.unidades DESC;

CREATE OR REPLACE FUNCTION lakehouse_rotaperfume.gold.checar_disponibilidade(
  p_sku STRING COMMENT 'Codigo do produto.'
)
RETURNS TABLE (
  sku STRING,
  descricao STRING,
  marca STRING,
  saldo INT,
  em_ruptura BOOLEAN,
  data_do_snapshot DATE
)
COMMENT 'Use SEMPRE antes de prometer um produto ao cliente. Devolve o saldo e se o item esta em ruptura, segundo a foto de estoque mais recente. Nunca informe quantidade de estoque sem chamar esta funcao.'
RETURN
  SELECT e.sku, p.descricao, p.marca, e.saldo, e.ruptura, e.data_snapshot
  FROM (
    SELECT sku, saldo, ruptura, data_snapshot,
           ROW_NUMBER() OVER (PARTITION BY sku ORDER BY data_snapshot DESC) AS posicao
    FROM lakehouse_rotaperfume.silver.estoque
    WHERE sku = p_sku
  ) e
  LEFT JOIN lakehouse_rotaperfume.gold.dim_produto p ON p.sku = e.sku
  WHERE e.posicao = 1;

-- ============================================================================
-- OS TRES TESTES QUE QUEBRAM O JOB
-- Mesmo padrao da noite 2: raise_error() dentro de CASE WHEN.
-- ============================================================================

-- 1 - a fila tem exatamente 200 linhas. Se vier menos, o descarte de vendedor
--     desligado rodou DEPOIS do LIMIT.
SELECT CASE
         WHEN COUNT(*) = 200 THEN 'TESTE 1 OK: 200 contatos na fila'
         ELSE raise_error(concat(
           'FILA COM TAMANHO ERRADO: ', CAST(COUNT(*) AS STRING), ' linhas em vez de 200. ',
           'Quase sempre e o filtro de carteira vigente rodando DEPOIS do LIMIT 200.'))
       END AS resultado
FROM lakehouse_rotaperfume.gold.fila_semanal;

-- 2 - nenhum motivo nulo ou vazio. Linha sem motivo e linha que o vendedor
--     ignora -- e some o ELSE do CASE WHEN.
SELECT CASE
         WHEN COUNT(*) = 0 THEN 'TESTE 2 OK: todo contato tem motivo escrito'
         ELSE raise_error(concat(
           'MOTIVO AUSENTE em ', CAST(COUNT(*) AS STRING), ' contato(s). ',
           'Faltou o ELSE no CASE WHEN do motivo.'))
       END AS resultado
FROM lakehouse_rotaperfume.gold.fila_semanal
WHERE motivo IS NULL OR trim(motivo) = '';

-- 3 - score dentro de [0, 1]. Fora disso nao e probabilidade, e outra coisa.
SELECT CASE
         WHEN COUNT(*) = 0 THEN 'TESTE 3 OK: todo score entre 0 e 1'
         ELSE raise_error(concat(
           'SCORE FORA DE [0,1] em ', CAST(COUNT(*) AS STRING), ' contato(s). ',
           'Provavel uso de pyfunc.predict (classe) no lugar de predict_proba.'))
       END AS resultado
FROM lakehouse_rotaperfume.gold.fila_semanal
WHERE score < 0 OR score > 1 OR score IS NULL;
