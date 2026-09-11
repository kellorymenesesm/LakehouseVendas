-- =====================================================================
-- GOLD . TESTES DE QUALIDADE
--
-- Teste que nao quebra o job nao e teste, e relatorio. Se a verificacao
-- falha e o pipeline segue, o dashboard mostra numero errado com cara
-- de numero certo.
--
-- Os nove testes gravam o resultado em gold._testes_qualidade e o
-- ULTIMO statement levanta a excecao, nomeando todos os que falharam.
-- Assim os nove sao sempre avaliados (e nao so ate o primeiro erro) e
-- a evidencia sobrevive a execucao - a saida de sql_task no log do job
-- vem vazia.
-- =====================================================================

CREATE OR REPLACE TABLE lakehouse_rotaperfume.gold._testes_qualidade
COMMENT 'Resultado da ultima execucao dos 9 testes de qualidade do pipeline. Se alguma linha tiver passou = false, o job parou.'
AS
-- 1 - O TESTE QUE MAIS IMPORTA: limpeza e modelagem nao podem mudar o
--     faturamento. Se este falhar, alguem jogou dado fora sem querer.
SELECT 1 AS numero,
       'receita da gold igual a da silver' AS nome,
       CAST((SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas) AS STRING) AS valor,
       CAST((SELECT ROUND(SUM(valor_liquido), 2) FROM lakehouse_rotaperfume.silver.pedidos) AS STRING) AS esperado,
       abs((SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)
         - (SELECT SUM(valor_liquido) FROM lakehouse_rotaperfume.silver.pedidos)) <= 0.01 AS passou

UNION ALL SELECT 2,
       'CNPJ unico na silver.clientes',
       CAST((SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_rotaperfume.silver.clientes) AS STRING),
       '0',
       (SELECT COUNT(*) - COUNT(DISTINCT cnpj) FROM lakehouse_rotaperfume.silver.clientes) = 0

UNION ALL SELECT 3,
       'nenhuma data_pedido nula na silver',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.pedidos WHERE data_pedido IS NULL) AS STRING),
       '0',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.pedidos WHERE data_pedido IS NULL) = 0

UNION ALL SELECT 4,
       'receita negativa so onde devolucao',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas WHERE receita < 0 AND NOT devolucao) AS STRING),
       '0',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas WHERE receita < 0 AND NOT devolucao) = 0

UNION ALL SELECT 5,
       'volume do fato entre 140.000 e 250.000',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas) AS STRING),
       'entre 140000 e 250000',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas) BETWEEN 140000 AND 250000

UNION ALL SELECT 6,
       'nenhum pedido_id da gold fora da silver',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
             LEFT JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id
             WHERE p.pedido_id IS NULL) AS STRING),
       '0',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
        LEFT JOIN lakehouse_rotaperfume.silver.pedidos p ON p.pedido_id = f.pedido_id
        WHERE p.pedido_id IS NULL) = 0

UNION ALL SELECT 7,
       'nenhum cliente_id da gold fora da silver',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
             LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
             WHERE c.cliente_id IS NULL) AS STRING),
       '0',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.gold.fato_vendas f
        LEFT JOIN lakehouse_rotaperfume.silver.clientes c ON c.cliente_id = f.cliente_id
        WHERE c.cliente_id IS NULL) = 0

UNION ALL SELECT 8,
       'mart_produto soma o mesmo que o fato',
       CAST((SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.mart_produto_performance) AS STRING),
       CAST((SELECT ROUND(SUM(receita), 2) FROM lakehouse_rotaperfume.gold.fato_vendas) AS STRING),
       abs((SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.mart_produto_performance)
         - (SELECT SUM(receita) FROM lakehouse_rotaperfume.gold.fato_vendas)) <= 0.01

UNION ALL SELECT 9,
       'todo CNPJ com 14 digitos',
       CAST((SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes WHERE length(cnpj) <> 14) AS STRING),
       '0',
       (SELECT COUNT(*) FROM lakehouse_rotaperfume.silver.clientes WHERE length(cnpj) <> 14) = 0;

-- =====================================================================
-- O DENTE. Enquanto este statement existir, numero errado nao passa.
-- Se falhar, o dashboard fica com o dado de ONTEM - que e de longe o
-- melhor dos dois cenarios ruins.
-- =====================================================================
SELECT CASE
         WHEN COUNT(*) = 0 THEN 'OS 9 TESTES PASSARAM'
         ELSE raise_error(concat('TESTES DE QUALIDADE FALHARAM: ',
                                 array_join(collect_list(nome), ' | ')))
       END AS resultado
FROM lakehouse_rotaperfume.gold._testes_qualidade
WHERE NOT passou;
