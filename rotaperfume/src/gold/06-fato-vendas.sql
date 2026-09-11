-- =====================================================================
-- GOLD . FATO_VENDAS
--
-- O CONTRATO, escrito ANTES do SQL. Se esta frase nao existir, seis
-- meses de discussao tomam o lugar dela.
--
--   GRANULARIDADE  uma linha por ITEM de pedido.
--                  191.080 linhas = 197.724 itens da silver menos os
--                  6.644 itens dos 957 pedidos cancelados.
--
--   FILTRO         exclui pedido CANCELADO.
--                  NAO exclui DEVOLUCAO.
--
--   DIMENSOES      data_pedido, ano, mes, canal, cliente_id,
--                  razao_social, segmento, cidade, vendedor_id,
--                  sku, categoria, marca, nota_olfativa
--
--   METRICAS       quantidade, preco_praticado, receita, custo, margem
--                  receita = quantidade * preco_praticado
--                  custo   = quantidade * custo_unitario
--                  margem  = receita - custo
--
--   POR QUE A DEVOLUCAO FICA DENTRO
--   Devolucao entra com quantidade e receita NEGATIVAS, sinalizada.
--   Se ficasse de fora, a gold somaria R$ 103.568.586,35 e a silver
--   R$ 102.303.828,05: R$ 1,26 milhao de diferenca entre duas camadas
--   do MESMO pipeline. Quem quiser o bruto pede explicitamente:
--       SUM(receita) FILTER (WHERE NOT devolucao)
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold.fato_vendas
PARTITIONED BY (ano, mes)
COMMENT 'Fato de vendas no grao de item de pedido. Exclui pedido cancelado e INCLUI devolucao com sinal negativo. Soma R$ 102.303.828,05 - o mesmo numero da silver.'
AS
SELECT
  i.item_id,
  i.pedido_id,
  p.data_pedido,
  p.canal,
  p.cliente_id,
  c.razao_social,
  c.segmento,
  c.cidade,
  c.uf,
  p.vendedor_id,
  i.sku,
  pr.categoria,
  pr.marca,
  pr.nota_olfativa,
  i.quantidade,
  i.preco_praticado,
  i.quantidade * i.preco_praticado AS receita,
  i.quantidade * pr.custo_unitario AS custo,
  i.quantidade * i.preco_praticado - i.quantidade * pr.custo_unitario AS margem,
  i.devolucao,
  i.sku_descontinuado,
  current_timestamp() AS _processado_em,
  p.ano,
  p.mes
FROM lakehouse_rotaperfume.silver.itens_pedido i
JOIN lakehouse_rotaperfume.silver.pedidos   p  ON p.pedido_id  = i.pedido_id
JOIN lakehouse_rotaperfume.silver.produtos  pr ON pr.sku       = i.sku
JOIN lakehouse_rotaperfume.silver.clientes  c  ON c.cliente_id = p.cliente_id
WHERE NOT p.cancelado;

-- =====================================================================
-- COMMENT em TODAS as colunas, com significado de NEGOCIO.
-- Isto nao e capricho: e o que o Genie le para escolher a coluna certa.
-- Coluna sem comentario e coluna que ele usa errado, com confianca.
-- =====================================================================
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN item_id
  COMMENT 'Identificador do item dentro do pedido. Define o grao desta tabela: uma linha por item.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN pedido_id
  COMMENT 'Pedido ao qual o item pertence. Um pedido tem cerca de 7 itens.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN data_pedido
  COMMENT 'Data em que o pedido foi feito. E a data de referencia de toda analise temporal de vendas.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN canal
  COMMENT 'Como a venda entrou: Visita, WhatsApp, Telefone ou E-commerce.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cliente_id
  COMMENT 'Cliente que comprou. Ja deduplicado por CNPJ na silver.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN razao_social
  COMMENT 'Nome da empresa cliente, padronizado.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN segmento
  COMMENT 'Tipo de ponto de venda do cliente: loja de shopping, quiosque, revendedora autonoma e afins.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN cidade
  COMMENT 'Cidade do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN uf
  COMMENT 'Unidade federativa do cliente.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN vendedor_id
  COMMENT 'Vendedor responsavel pelo pedido.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku
  COMMENT 'Codigo do produto vendido.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN categoria
  COMMENT 'Categoria do produto. Kit Presente tem a menor margem (33%) e Oleo Concentrado a maior (50%).';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN marca
  COMMENT 'Marca do produto. Layali e a lider de receita.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN nota_olfativa
  COMMENT 'Nota olfativa predominante do produto: oud, rosa, cedro e afins.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN quantidade
  COMMENT 'Unidades vendidas. NEGATIVA quando a linha e devolucao - some com sinal e o resultado ja e liquido.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN preco_praticado
  COMMENT 'Preco unitario efetivamente cobrado, ja com o desconto comercial aplicado. Pode ser menor que o preco de tabela.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN receita
  COMMENT 'Quantidade vezes preco praticado. Negativa nas devolucoes. A soma desta coluna e o faturamento liquido da empresa. Para o bruto, filtre NOT devolucao.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN custo
  COMMENT 'Quantidade vezes custo unitario do produto. Nao inclui frete, comissao nem impostos.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN margem
  COMMENT 'Receita menos custo do produto. Nao considera desconto comercial adicional, frete nem comissao de vendedor.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN devolucao
  COMMENT 'Verdadeiro quando a linha e uma devolucao (quantidade negativa na origem). Devolucao NAO foi excluida do fato: excluir infla o faturamento em R$ 1,26 milhao.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN sku_descontinuado
  COMMENT 'Verdadeiro quando o produto vendido nao esta mais ativo no catalogo hoje. A venda aconteceu do mesmo jeito.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN ano
  COMMENT 'Ano do pedido. Coluna de particao.';
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN mes
  COMMENT 'Mes do pedido, de 1 a 12. Coluna de particao. Outubro e o pico do setor, janeiro o vale.';
-- Coluna tecnica, e mesmo assim comentada: a auditoria de metadado exige 100%
-- das colunas do fato, e "e so controle" e exatamente a desculpa que deixa uma
-- coluna sem explicacao na frente do agente.
ALTER TABLE lakehouse_rotaperfume.gold.fato_vendas ALTER COLUMN _processado_em
  COMMENT 'Quando esta linha foi gravada pelo pipeline. Coluna de controle, nao de negocio: nao use para analise temporal de vendas - a data do pedido e data_pedido.';
