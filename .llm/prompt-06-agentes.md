# Prompt 6 · Agentes de IA — o mesmo dado, outra porta

**Entrega:** views com nome de negócio, auditoria de metadado, o Genie space
configurado e as instruções do agente. **Deploy nº 6 — o último.**

> **O fechamento perfeito, porque fecha o arco da noite 1.** Ontem você plugou o
> Genie direto na bronze e avisou ao vivo: *"pode dar certo e pode dar errado,
> não fui eu que limpei esses dados"*. Hoje você mostra a diferença.

---

## O que mostrar antes

Três telas, e a terceira é a que explica por que o Genie de ontem errou.

**1 · A gold ainda não fala a língua da diretoria**

```sql
SHOW VIEWS IN lakehouse_rotaperfume.gold;    -- nenhuma
SHOW TABLES IN lakehouse_rotaperfume.gold;   -- dim_*, fato_vendas, mart_* — nomes de engenheiro
```

> *"Ninguém da diretoria pergunta por `mart_produto_performance`. Perguntam
> 'quais marcas estão vendendo' e 'quem parou de comprar'."*

**2 · Onde o metadado está furado hoje**

```sql
-- colunas da gold sem COMMENT: é exatamente o que o agente NÃO consegue usar
SELECT table_name, COUNT(*) AS colunas_sem_comentario
FROM lakehouse_rotaperfume.information_schema.columns
WHERE table_schema = 'gold' AND (comment IS NULL OR comment = '')
GROUP BY table_name ORDER BY 2 DESC;

-- e as tabelas sem COMMENT
SELECT table_name, comment
FROM lakehouse_rotaperfume.information_schema.tables
WHERE table_schema = 'gold' AND (comment IS NULL OR comment = '');
```

**3 · A pergunta de ontem, ainda na bronze**

Abra o Genie da noite 1 — o que aponta para a bronze — e repita a pergunta:

> *"Quais marcas mais venderam nos últimos 6 meses?"*

Guarde o SQL que ele gerou (o botão *Show generated code*). Você vai comparar
com o de hoje daqui a vinte minutos, e a diferença é o argumento inteiro da
noite: **o modelo é o mesmo; o que mudou está embaixo dele.**

---

**Enquanto ele trabalha, você explica:**

- **O que faz o agente funcionar não é o modelo — é o dado.** O mesmo Genie, o
  mesmo LLM, a mesma pergunta. O que mudou nas duas horas foi tudo que está
  embaixo dele.
- **Metadado é interface.** `COMMENT` não é documentação para humano ler: é o
  que o agente lê para decidir qual coluna usar. Uma coluna chamada `vl_liq`
  sem comentário é uma coluna que o agente vai errar.
- **View com nome de negócio.** Ninguém da diretoria pergunta por
  `fato_vendas`. Perguntam por *ranking de marcas* e *clientes em risco*. A
  view existe para que o nome da pergunta e o nome da tabela sejam o mesmo.
- **Regra de negócio que o modelo não tem como adivinhar:** a sazonalidade
  invertida. Sem essa instrução, o agente lê o gráfico ao contrário e diz que
  dezembro foi ruim — quando dezembro é vale **por desenho** do setor.

---

## O prompt

```
Continue o bundle em aulas/aula-02-engenharia-de-dados/rotaperfume/.
A gold está modelada, testada e no dashboard. Última entrega: preparar tudo
para consumo por linguagem natural.

1. src/gold/09-metricas-negocio.sql
   Crie views nomeadas como uma pessoa de negócio nomearia — em português, sem
   prefixo técnico:
     gold.receita_mensal        receita, margem e pedidos por mês, com a coluna
                                mes_pico_setor vinda da dim_calendario
     gold.ranking_marcas        marca → receita, margem %, participação %
     gold.margem_por_categoria  categoria → receita, margem, margem %
     gold.clientes_em_risco     sem compra há mais de 90 dias, com quanto
                                compravam por mês antes de sumir
     gold.efeito_lancamento     receita dos SKUs nos 120 dias após o lançamento
                                contra o resto do período
     gold.ruptura_por_marca     % de snapshots em ruptura por marca
   COMMENT em cada view dizendo QUAL PERGUNTA DE NEGÓCIO ela responde — não o
   que ela é. É assim que o Genie escolhe onde procurar.
   Use a forma compacta `CREATE OR REPLACE VIEW nome (col COMMENT '...', ...)`
   para comentar toda coluna sem precisar de um ALTER por coluna.

2. src/gold/10-auditoria-metadado.sql
   Consulte information_schema e QUEBRE com raise_error() se:
   - alguma tabela ou view da gold estiver sem COMMENT
   - alguma coluna de fato_vendas ou das 6 views estiver sem COMMENT
   Ao final, imprima um relatório de cobertura de metadado por objeto — sem
   quebrar. Serve para a conversa com quem vai consumir a gold.
   Metadado faltando é BUG, não pendência de documentação.

3. docs/genie-instrucoes.md
   O texto para colar na configuração do Genie space:
   - Contexto: distribuidora B2B de perfumaria árabe, vende para varejo
   - Glossário: ruptura, carteira, oportunidade, devolução, SKU, segmento,
     atingimento de meta, curva ABC
   - REGRA DE SAZONALIDADE, a mais importante: o pico da distribuidora é o mês
     ANTERIOR à data comemorativa, porque o varejo compra antes. Abril (Dia das
     Mães), junho (Namorados) e outubro (Black Friday) são picos; dezembro e
     janeiro são VALE, e isso é saudável, não é queda.
   - Regra de cálculo de cada métrica: receita, margem, ticket médio,
     atingimento, churn (90 dias sem compra)
   - Aviso: devolução entra com valor negativo. Para o bruto vendido,
     filtre devolucao = false.

4. O Genie space COMO CÓDIGO, dentro do bundle:
   - resources/comercial.geniespace.json com a definição serializada
   - resources/genie.genie_space.yml declarando o recurso `genie_spaces`,
     com title, description, file_path e warehouse_id

   Conteúdo do JSON: as 6 views + fato_vendas + as dimensões como data_sources,
   o texto de instruções acima em `instructions.text_instructions`, pelo menos
   5 perguntas de exemplo em `config.sample_questions`, e 6 pares
   pergunta→SQL em `instructions.example_question_sqls` com SQL já validado.

   QUATRO REGRAS DA API QUE FAZEM O DEPLOY FALHAR SE FOREM IGNORADAS:
   a) `data_sources.tables` tem que estar ORDENADO por `identifier`
   b) `column_configs` de cada tabela ordenado por `column_name`
   c) toda sample_question, text_instruction e example_question_sql precisa de
      um `id` de 32 caracteres hexadecimais minúsculos, sem hífen
   d) essas listas também têm que estar ORDENADAS por `id`

   Gere os ids de forma DETERMINÍSTICA (md5 do conteúdo da pergunta), nunca
   aleatória: assim um redeploy não recria as perguntas nem gera diff no Git
   sem motivo.

   A chave do recurso tem que ser diferente da chave do dashboard — o bundle
   recusa duas chaves iguais mesmo em tipos diferentes.

5. Acrescente ao pipeline as tarefas metricas_de_negocio e
   auditoria_de_metadado, nessa ordem, depois de gold_marts.

6. Rode:
   databricks bundle validate --target dev --profile projeto-dados-ia
   databricks bundle deploy   --target dev --profile projeto-dados-ia
   databricks bundle run rotaperfume_pipeline --target dev --profile projeto-dados-ia

   O pipeline completo tem que rodar verde de ponta a ponta, com 12 tarefas:
   raw → bronze → silver ×4 → dimensões → fato → marts → testes,
   e em paralelo métricas de negócio → auditoria de metadado
```

---

## Como verificar a feature

**1 · A cobertura de metadado é 100% — e isso é verificável, não é promessa**

```sql
-- tem que voltar VAZIO. Se voltar linha, a tarefa auditoria_de_metadado quebra o job.
SELECT table_name, column_name
FROM lakehouse_rotaperfume.information_schema.columns
WHERE table_schema = 'gold' AND (comment IS NULL OR comment = '')
ORDER BY table_name, column_name;

-- e o relatório de cobertura, objeto por objeto
SELECT c.table_name,
       COUNT(*)                                                        AS colunas,
       COUNT(*) FILTER (WHERE c.comment IS NOT NULL AND c.comment <> '') AS comentadas,
       ROUND(100.0 * COUNT(*) FILTER (WHERE c.comment IS NOT NULL AND c.comment <> '') / COUNT(*), 1) AS cobertura_pct
FROM lakehouse_rotaperfume.information_schema.columns c
WHERE c.table_schema = 'gold'
GROUP BY c.table_name ORDER BY cobertura_pct, c.table_name;
```

**2 · As seis views respondem perguntas, não mostram tabelas**

```sql
SHOW VIEWS IN lakehouse_rotaperfume.gold;

-- o COMMENT de cada uma é a PERGUNTA que ela responde — é o que o Genie lê
SELECT table_name, comment
FROM lakehouse_rotaperfume.information_schema.tables
WHERE table_schema = 'gold' AND table_type = 'VIEW'
ORDER BY table_name;

SELECT * FROM lakehouse_rotaperfume.gold.ranking_marcas       LIMIT 5;
SELECT * FROM lakehouse_rotaperfume.gold.margem_por_categoria ORDER BY 1;
SELECT * FROM lakehouse_rotaperfume.gold.clientes_em_risco     LIMIT 10;
SELECT * FROM lakehouse_rotaperfume.gold.receita_mensal        ORDER BY 1;
```

E a checagem que fecha o arco com a noite inteira: **as views não podem inventar
número.**

```sql
SELECT
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_rotaperfume.gold.fato_vendas)    AS fato,
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_rotaperfume.gold.receita_mensal) AS view_mensal,
  (SELECT ROUND(SUM(receita),2) FROM lakehouse_rotaperfume.gold.ranking_marcas) AS view_marcas;
-- as três colunas: R$ 102.303.828,05
```

**3 · A auditoria tem dente — quebre de propósito**

```sql
-- crie uma view sem COMMENT nenhum, de propósito
CREATE OR REPLACE VIEW lakehouse_rotaperfume.gold._sem_comentario AS SELECT 1 AS x;
```

```bash
databricks bundle run rotaperfume_pipeline --target dev --profile projeto-dados-ia
# a tarefa auditoria_de_metadado FALHA: objeto da gold sem COMMENT
```

```sql
DROP VIEW lakehouse_rotaperfume.gold._sem_comentario;   -- e rode de novo: verde
```

> *"Metadado faltando não é pendência de documentação. É bug — porque a partir
> de hoje tem um agente lendo esse comentário para decidir qual coluna usar."*

**4 · O pipeline inteiro, com as 12 tarefas**

```bash
databricks bundle run rotaperfume_pipeline --target dev --profile projeto-dados-ia
```

Abra o DAG e conte na tela: raw → bronze → silver ×4 → dimensões → fato →
marts → testes, e em paralelo métricas de negócio → auditoria de metadado.

**5 · O clímax da noite — o mesmo Genie, o mesmo modelo, outro dado**

Faça no Genie a **mesma pergunta de ontem**, agora sobre a gold:

> *"Quais marcas mais venderam nos últimos 6 meses?"*

Abra o *Show generated code* e coloque lado a lado com o SQL que você guardou
antes de começar: o de ontem tinha `CAST` e `try_to_date` e lia a bronze; o de
hoje é um `SELECT` na view. Confira o número na mão:

```sql
SELECT marca, ROUND(SUM(receita)/1e6, 1) AS receita_mi
FROM lakehouse_rotaperfume.gold.fato_vendas
WHERE data_pedido >= add_months(current_date(), -6)
GROUP BY marca ORDER BY 2 DESC LIMIT 5;
```

Depois a pergunta que **só funciona com dado limpo e documentado**:

> *"Quais clientes pararam de comprar, e quanta receita a gente perdeu com isso?"*

```sql
-- o que ele deveria estar lendo para responder
SELECT COUNT(*) AS clientes_em_risco FROM lakehouse_rotaperfume.gold.clientes_em_risco;
-- 503 clientes · cerca de R$ 836 mil por mês de receita parada
```

E a que prova que ele entendeu o negócio:

> *"Dezembro foi um mês ruim?"*
>
> A resposta certa é **não** — é vale de setor. Se ele responder que sim, a
> instrução de sazonalidade não entrou.
>
> **Resposta obtida no teste, palavra por palavra:** *"Dezembro é marcado como
> um mês de vale no setor, o que significa que é esperado ter menor receita,
> não sendo considerado um mês ruim. (…) Esse comportamento é normal, pois o
> varejo já está abastecido após os picos de vendas anteriores."*

E a query que mostra que ele está certo:

```sql
SELECT ano, mes, ROUND(SUM(receita)/1e6, 2) AS receita_mi
FROM lakehouse_rotaperfume.gold.fato_vendas
WHERE ano = 2025 AND mes IN (10, 11, 12)
   OR ano = 2026 AND mes = 1
GROUP BY ano, mes ORDER BY ano, mes;
-- outubro 7,02 · ... · janeiro 2,46. O vale é do setor, não da empresa.
```

---

## Fala de fechamento da noite

> *"Ontem eu pluguei o Genie direto na bronze e falei para vocês, com todas as
> letras: pode dar certo, pode dar errado, não fui eu que limpei esses dados.*
>
> *Hoje eu sei que está certo. E não é porque o modelo ficou mais inteligente
> de ontem para hoje — é o mesmo modelo. É porque eu construí o caminho inteiro
> e testei cada passo.*
>
> *Engenharia de dados não é o que a IA substitui. É o que faz a IA funcionar."*


---

## Se der errado ao vivo

| Sintoma | Causa | Correção em um prompt |
|---|---|---|
| `data_sources.tables must be sorted by identifier` | A lista está fora de ordem | Ordene por `identifier` |
| `sample_question.id must be provided` | Falta o id de 32 hex | Gere com md5 do conteúdo da pergunta |
| `example_question_sqls must be sorted by id` | As listas também são ordenadas | Ordene todas as listas por `id` |
| `multiple resources defined with the same key` | Dashboard e Genie usam a mesma chave | Renomeie uma das duas |
| O Genie responde que dezembro foi ruim | A instrução de sazonalidade não entrou | *"Reforce no texto que dezembro e janeiro são vale ESPERADO, e que ele nunca deve chamar isso de queda."* |
| Ele usa a bronze | As tabelas da bronze entraram como data_source | Só a gold entra. Escreva isso na instrução também |

**Tempo medido:** ~1min30 de deploy, ~4min30 do pipeline completo com 12 tarefas.

---

## O que fica de pé no fim da noite

| Camada | O quê |
|---|---|
| `bronze.raw` | Volume com os 10 CSVs, 14,7 MB |
| `bronze` | 10 tabelas Delta + a tabela de controle `_raw_arquivos` |
| `silver` | 10 tabelas limpas, com 5 constraints declaradas |
| `gold` | 4 dimensões, `fato_vendas` (191.080 linhas), 3 marts e 6 views de negócio |
| Job | `rotaperfume_pipeline`, 12 tarefas, agendado, com 11 testes que quebram |
| Dashboard | `Rota do Perfume · Comercial`, JSON versionado no bundle |
| Genie | `Rota do Perfume · Comercial`, instruções versionadas no bundle |

Tudo isso a partir de **seis prompts** e um catálogo vazio.
