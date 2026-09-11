-- ============================================================================
-- GOLD . METRICAS DE NEGOCIO
--
-- Seis views nomeadas como uma pessoa de negocio nomearia. Ninguem da diretoria
-- pergunta por `mart_produto_performance`: pergunta "quais marcas estao
-- vendendo" e "quem parou de comprar". A view existe para que o nome da
-- pergunta e o nome da tabela sejam o mesmo.
--
-- O COMMENT de cada view diz QUAL PERGUNTA ela responde -- nao o que ela e.
-- E assim que o Genie escolhe onde procurar: metadado aqui nao e documentacao
-- para humano ler, e a interface que o agente le para decidir qual coluna usar.
--
-- Forma compacta `CREATE OR REPLACE VIEW nome (col COMMENT '...')`: comenta
-- toda coluna sem um ALTER por coluna. A lista de colunas TEM que ter o mesmo
-- tamanho do SELECT, na mesma ordem.
--
-- ARMADILHA DO AMBIENTE: ANSI mode ligado -- divisao por zero ABORTA a query.
-- Toda razao aqui passa por TRY_DIVIDE.
--
-- ARMADILHA DE DATA: o "hoje" deste dataset e 2026-08-31, a ultima data de
-- pedido. current_date() daria 631 clientes em risco em vez de 503, porque
-- conta os dias que passaram desde que o dado foi gerado.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. RECEITA MENSAL -- a serie temporal, com o pico do setor marcado na linha.
--    mes_pico_setor vem da dim_calendario: e ele que impede o agente de ler
--    dezembro como queda. Dezembro e vale POR DESENHO do setor.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.receita_mensal (
  ano            COMMENT 'Ano do pedido.',
  mes            COMMENT 'Mes do pedido, de 1 a 12.',
  nome_mes       COMMENT 'Nome do mes por extenso, em portugues.',
  mes_pico_setor COMMENT 'Verdadeiro em abril, junho e outubro - os meses ANTERIORES a Dia das Maes, Namorados e Black Friday. O varejo compra antes, entao o pico da distribuidora vem um mes antes da data comemorativa. Dezembro e janeiro sao VALE esperado, nao queda.',
  receita        COMMENT 'Receita liquida do mes, em reais. Devolucao ja entra com sinal negativo. Para o bruto vendido, use fato_vendas com devolucao = false.',
  margem         COMMENT 'Margem bruta do mes, em reais: receita menos custo do produto. Nao considera frete nem comissao.',
  margem_pct     COMMENT 'Margem dividida pela receita, em porcentagem.',
  pedidos        COMMENT 'Pedidos distintos faturados no mes.',
  clientes       COMMENT 'Clientes distintos que compraram no mes.',
  ticket_medio   COMMENT 'Receita dividida pelo numero de pedidos do mes, em reais.'
)
COMMENT 'Responde: como a receita e a margem evoluiram mes a mes, e quais meses sao pico do setor? Serie mensal de vendas com a marcacao de sazonalidade - use SEMPRE a coluna mes_pico_setor antes de dizer que um mes foi bom ou ruim.'
AS
SELECT
  c.ano,
  c.mes,
  c.nome_mes,
  c.mes_pico_setor,
  ROUND(SUM(f.receita), 2)                                              AS receita,
  ROUND(SUM(f.margem), 2)                                               AS margem,
  ROUND(100 * TRY_DIVIDE(SUM(f.margem), SUM(f.receita)), 2)             AS margem_pct,
  COUNT(DISTINCT f.pedido_id)                                           AS pedidos,
  COUNT(DISTINCT f.cliente_id)                                          AS clientes,
  ROUND(TRY_DIVIDE(SUM(f.receita), COUNT(DISTINCT f.pedido_id)), 2)     AS ticket_medio
FROM lakehouse_rotaperfume.gold.fato_vendas f
JOIN lakehouse_rotaperfume.gold.dim_calendario c
  ON f.data_pedido = c.dia
GROUP BY c.ano, c.mes, c.nome_mes, c.mes_pico_setor;

-- ----------------------------------------------------------------------------
-- 2. RANKING DE MARCAS -- a pergunta mais feita da noite 1, agora com nome.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ranking_marcas (
  posicao          COMMENT 'Posicao da marca no ranking de receita, sendo 1 a marca que mais vendeu no periodo inteiro.',
  marca            COMMENT 'Marca do produto.',
  receita          COMMENT 'Receita liquida acumulada da marca, em reais, em todo o periodo.',
  margem           COMMENT 'Margem bruta acumulada da marca, em reais.',
  margem_pct       COMMENT 'Margem dividida pela receita da propria marca, em porcentagem.',
  participacao_pct COMMENT 'Quanto a marca representa da receita total da empresa, em porcentagem. As participacoes somam 100.',
  skus             COMMENT 'Quantos produtos distintos da marca foram vendidos.',
  clientes         COMMENT 'Quantos clientes distintos compraram a marca.',
  pedidos          COMMENT 'Pedidos distintos que continham ao menos um item da marca.'
)
COMMENT 'Responde: quais marcas mais venderam, com que margem e com que participacao no faturamento? Ranking de marcas do periodo inteiro - para recortar por tempo, some a partir de fato_vendas filtrando data_pedido.'
AS
SELECT
  RANK() OVER (ORDER BY SUM(receita) DESC)                                     AS posicao,
  marca,
  ROUND(SUM(receita), 2)                                                       AS receita,
  ROUND(SUM(margem), 2)                                                        AS margem,
  ROUND(100 * TRY_DIVIDE(SUM(margem), SUM(receita)), 2)                        AS margem_pct,
  ROUND(100 * TRY_DIVIDE(SUM(receita), SUM(SUM(receita)) OVER ()), 2)          AS participacao_pct,
  COUNT(DISTINCT sku)                                                          AS skus,
  COUNT(DISTINCT cliente_id)                                                   AS clientes,
  COUNT(DISTINCT pedido_id)                                                    AS pedidos
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY marca;

-- ----------------------------------------------------------------------------
-- 3. MARGEM POR CATEGORIA -- onde a empresa ganha dinheiro, nao onde ela fatura.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.margem_por_categoria (
  categoria        COMMENT 'Categoria do produto: Kit Presente, Oleo Concentrado, Agua de Perfume e afins.',
  receita          COMMENT 'Receita liquida acumulada da categoria, em reais.',
  margem           COMMENT 'Margem bruta acumulada da categoria, em reais.',
  margem_pct       COMMENT 'Margem dividida pela receita da propria categoria, em porcentagem. Kit Presente e a menor do catalogo (cerca de 33%) e Oleo Concentrado a maior (cerca de 50%).',
  participacao_pct COMMENT 'Quanto a categoria representa da receita total da empresa, em porcentagem.',
  skus             COMMENT 'Quantos produtos distintos da categoria foram vendidos.',
  quantidade       COMMENT 'Unidades vendidas da categoria, ja liquidas de devolucao.'
)
COMMENT 'Responde: qual categoria da mais margem, e qual so da volume? Rentabilidade por categoria de produto - a categoria que mais fatura nao e a que mais lucra, e esta view mostra as duas colunas lado a lado.'
AS
SELECT
  categoria,
  ROUND(SUM(receita), 2)                                              AS receita,
  ROUND(SUM(margem), 2)                                               AS margem,
  ROUND(100 * TRY_DIVIDE(SUM(margem), SUM(receita)), 2)               AS margem_pct,
  ROUND(100 * TRY_DIVIDE(SUM(receita), SUM(SUM(receita)) OVER ()), 2) AS participacao_pct,
  COUNT(DISTINCT sku)                                                 AS skus,
  SUM(quantidade)                                                     AS quantidade
FROM lakehouse_rotaperfume.gold.fato_vendas
GROUP BY categoria;

-- ----------------------------------------------------------------------------
-- 4. CLIENTES EM RISCO -- quem parou de comprar, e quanto ia embora com ele.
--
--    receita_media_mensal e NULL para quem comprou UMA vez so: sem dois pedidos
--    nao existe janela para medir ritmo, e inventar um numero aqui seria pior
--    que deixar vazio. Sao 55 dos 503. E a mesma disciplina do atraso_relativo
--    em gold.features_cliente.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.clientes_em_risco (
  cliente_id           COMMENT 'Identificador do cliente.',
  razao_social         COMMENT 'Nome da empresa cliente.',
  segmento             COMMENT 'Tipo de ponto de venda: loja de shopping, quiosque, revendedora autonoma e afins.',
  cidade               COMMENT 'Cidade do cliente.',
  uf                   COMMENT 'Unidade federativa do cliente.',
  ultima_compra        COMMENT 'Data do ultimo pedido do cliente.',
  dias_sem_comprar     COMMENT 'Dias entre a ultima compra e 2026-08-31, o dia de referencia do dataset. Churn nesta empresa e mais de 90 dias sem comprar.',
  primeira_compra      COMMENT 'Data do primeiro pedido do cliente.',
  pedidos              COMMENT 'Pedidos distintos que o cliente fez enquanto estava ativo.',
  receita_historica    COMMENT 'Receita liquida total que o cliente gerou enquanto comprava, em reais.',
  receita_media_mensal COMMENT 'Quanto o cliente comprava por mes enquanto estava ativo, em reais: receita historica dividida pelos meses entre a primeira e a ultima compra. E NULL para quem comprou uma unica vez - sem dois pedidos nao ha janela para medir. A soma desta coluna e a receita mensal que parou de entrar.'
)
COMMENT 'Responde: quais clientes pararam de comprar, e quanta receita por mes parou junto? Clientes com mais de 90 dias sem pedido - a regra de churn desta empresa - com quanto cada um comprava por mes antes de sumir.'
AS
SELECT
  h.cliente_id,
  h.razao_social,
  h.segmento,
  h.cidade,
  h.uf,
  h.ultima_compra,
  DATEDIFF(DATE'2026-08-31', h.ultima_compra)                                  AS dias_sem_comprar,
  h.primeira_compra,
  h.pedidos,
  ROUND(h.receita_historica, 2)                                                AS receita_historica,
  ROUND(
    TRY_DIVIDE(h.receita_historica,
               NULLIF(DATEDIFF(h.ultima_compra, h.primeira_compra) / 30.0, 0)), 2
  )                                                                            AS receita_media_mensal
FROM (
  SELECT
    cliente_id,
    MAX(razao_social)          AS razao_social,
    MAX(segmento)              AS segmento,
    MAX(cidade)                AS cidade,
    MAX(uf)                    AS uf,
    MAX(data_pedido)           AS ultima_compra,
    MIN(data_pedido)           AS primeira_compra,
    COUNT(DISTINCT pedido_id)  AS pedidos,
    SUM(receita)               AS receita_historica
  FROM lakehouse_rotaperfume.gold.fato_vendas
  GROUP BY cliente_id
) h
WHERE DATEDIFF(DATE'2026-08-31', h.ultima_compra) > 90;

-- ----------------------------------------------------------------------------
-- 5. EFEITO LANCAMENTO -- o SKU novo vende mesmo, ou so parece?
--
--    So 47 dos 292 SKUs tem data_lancamento preenchida: os outros 245 ja
--    estavam no catalogo antes do periodo e nao sao lancamento de nada. O
--    INNER JOIN com o filtro NOT NULL e o que define o universo da view.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.efeito_lancamento (
  sku                COMMENT 'Codigo do produto.',
  descricao          COMMENT 'Nome do produto.',
  marca              COMMENT 'Marca do produto.',
  categoria          COMMENT 'Categoria do produto.',
  data_lancamento    COMMENT 'Data em que o SKU entrou na linha. So 47 dos 292 produtos tem lancamento registrado - os demais ja existiam antes do periodo e ficam de fora desta view.',
  receita_120d       COMMENT 'Receita liquida do SKU nos 120 primeiros dias apos o lancamento, em reais. E a janela de novidade.',
  receita_apos_120d  COMMENT 'Receita liquida do SKU depois dos 120 primeiros dias, em reais. E o que sobrou quando a novidade passou.',
  receita_total      COMMENT 'Receita liquida acumulada do SKU no periodo inteiro, em reais.',
  pct_nos_120d       COMMENT 'Quanto da receita total do SKU saiu nos 120 primeiros dias, em porcentagem. Perto de 100 significa que o produto vendeu na novidade e parou.',
  unidades_120d      COMMENT 'Unidades vendidas nos 120 primeiros dias apos o lancamento.',
  clientes_120d      COMMENT 'Clientes distintos que compraram o SKU nos 120 primeiros dias.',
  dias_no_catalogo   COMMENT 'Dias entre o lancamento e 2026-08-31, o dia de referencia do dataset.'
)
COMMENT 'Responde: o produto lancado vendeu de verdade, ou so vendeu enquanto era novidade? Compara a receita dos 120 dias seguintes ao lancamento de cada SKU com a receita do resto do periodo.'
AS
SELECT
  p.sku,
  p.descricao,
  p.marca,
  p.categoria,
  p.data_lancamento,
  ROUND(SUM(CASE WHEN f.data_pedido < DATE_ADD(p.data_lancamento, 120) THEN f.receita ELSE 0 END), 2)  AS receita_120d,
  ROUND(SUM(CASE WHEN f.data_pedido >= DATE_ADD(p.data_lancamento, 120) THEN f.receita ELSE 0 END), 2) AS receita_apos_120d,
  ROUND(SUM(f.receita), 2)                                                                             AS receita_total,
  ROUND(100 * TRY_DIVIDE(
    SUM(CASE WHEN f.data_pedido < DATE_ADD(p.data_lancamento, 120) THEN f.receita ELSE 0 END),
    SUM(f.receita)), 2)                                                                                AS pct_nos_120d,
  SUM(CASE WHEN f.data_pedido < DATE_ADD(p.data_lancamento, 120) THEN f.quantidade ELSE 0 END)         AS unidades_120d,
  COUNT(DISTINCT CASE WHEN f.data_pedido < DATE_ADD(p.data_lancamento, 120) THEN f.cliente_id END)     AS clientes_120d,
  DATEDIFF(DATE'2026-08-31', p.data_lancamento)                                                        AS dias_no_catalogo
FROM lakehouse_rotaperfume.gold.dim_produto p
JOIN lakehouse_rotaperfume.gold.fato_vendas f
  ON f.sku = p.sku
WHERE p.data_lancamento IS NOT NULL
GROUP BY p.sku, p.descricao, p.marca, p.categoria, p.data_lancamento;

-- ----------------------------------------------------------------------------
-- 6. RUPTURA POR MARCA -- a marca que nao esta na prateleira nao vende.
--    Le silver.estoque: nao ha fato de estoque na gold, e o snapshot diario ja
--    esta limpo e tipado na silver. View da gold pode ler silver; o contrario
--    e que nao pode.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold.ruptura_por_marca (
  marca                COMMENT 'Marca do produto.',
  skus                 COMMENT 'Produtos distintos da marca acompanhados no estoque.',
  snapshots            COMMENT 'Fotos diarias de estoque tiradas para a marca no periodo. Cada linha da origem e um par produto-dia.',
  snapshots_em_ruptura COMMENT 'Quantas dessas fotos pegaram o produto com saldo zerado.',
  ruptura_pct          COMMENT 'Porcentagem das fotos de estoque em que a marca estava em ruptura. Ruptura e saldo zero: o produto existe no catalogo mas nao esta disponivel para venda. A media da empresa e cerca de 11,7%.',
  saldo_medio          COMMENT 'Saldo medio em unidades nas fotos de estoque da marca.',
  primeiro_snapshot    COMMENT 'Data da primeira foto de estoque considerada.',
  ultimo_snapshot      COMMENT 'Data da ultima foto de estoque considerada.'
)
COMMENT 'Responde: quais marcas mais faltam na prateleira? Percentual de dias em ruptura - saldo zero - por marca, a partir do snapshot diario de estoque.'
AS
SELECT
  p.marca,
  COUNT(DISTINCT e.sku)                                          AS skus,
  COUNT(*)                                                       AS snapshots,
  SUM(CASE WHEN e.ruptura THEN 1 ELSE 0 END)                     AS snapshots_em_ruptura,
  ROUND(100 * TRY_DIVIDE(SUM(CASE WHEN e.ruptura THEN 1 ELSE 0 END), COUNT(*)), 2) AS ruptura_pct,
  ROUND(AVG(e.saldo), 1)                                         AS saldo_medio,
  MIN(e.data_snapshot)                                           AS primeiro_snapshot,
  MAX(e.data_snapshot)                                           AS ultimo_snapshot
FROM lakehouse_rotaperfume.silver.estoque e
JOIN lakehouse_rotaperfume.gold.dim_produto p
  ON e.sku = p.sku
GROUP BY p.marca;
