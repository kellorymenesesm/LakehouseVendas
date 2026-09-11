# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## O que é este repositório

Material de uma aula de engenharia de dados (noite 2). O objetivo é construir,
em **seis entregas incrementais**, um lakehouse de vendas de perfumaria no
Databricks — tudo como código, via Declarative Automation Bundle (DAB).

Três partes, com papéis distintos:

Este arquivo está na raiz do repositório git. Os caminhos abaixo são relativos
a ele, e `../dados/` fica **um nível acima**, fora do versionamento.

| Caminho | Papel |
|---|---|
| `.llm/` | O roteiro de cada entrega: o prompt que a turma cola, o que verificar depois e os erros esperados. **Leia o prompt da entrega antes de codar.** Versionado. |
| `rotaperfume/` | O bundle (DAB). Versionado. |
| `../dados/` | Os 10 CSVs de origem (~15 MB, 313.551 linhas), em `projeto jornada/dados/`. **Fora do git de propósito** — sobem para um Volume do UC, não para o GitHub. É por isso que `scripts/subir-raw.sh` resolve o caminho como `../../dados`. |

Remoto: `github.com/kellorymenesesm/LakehouseVendas`.

`.llm/prompt_01.md` é a especificação viva da entrega 1 — inclui as armadilhas
já descobertas (ver "Restrições" abaixo), a ordem exata dos comandos e os
números esperados na conferência.

## Estado atual

**Entregas 1 a 4 concluídas e deployadas** (11/09/2026). No bundle:
`databricks.yml`, `resources/*.yml`, `scripts/*.sh`, `src/raw/conferencia.py`,
`src/bronze/ingestao.py`, `src/silver/0{1..4}-*.sql`, `src/gold/0{5..8}-*.sql`.

No workspace: 10 CSVs no Volume, 10 tabelas **bronze** (STRING puro), 10
**silver** (limpas, 5 CHECK constraints) e a **gold**: 4 dimensões,
`fato_vendas` (191.080 linhas, particionada por ano/mes), 3 marts e
`_testes_qualidade`. Job `rotaperfume_pipeline` (id 1044361054662476) verde com
**15 tarefas**, verde de ponta a ponta em 6,0 min: `raw_conferencia` →
`bronze_ingestao` → 4 silver em paralelo → `gold_dimensoes` → `gold_fato_vendas`
→ `gold_marts` → (`testes` ‖ `metricas_de_negocio` → `auditoria_de_metadado`),
e `ml_features` → `ml_modelo` → `ml_fila` depois de `testes`.
Agendado 6h, PAUSED. **Falta só a entrega 5, o dashboard** (`.llm/prompt-05-dashboard.md`).

**Camada de ML iniciada** (`.llm/prompt-01-features.md`, feito): `src/ml/11-features.py`
grava `gold.features_treino` (2.815 clientes, corte 2026-08-01, alvo
`comprou_em_7d` — **taxa base 10,12%**) e `gold.features_cliente` (2.816,
corte 2026-08-31, sem alvo), pela mesma `montar_features(referencia)`.
`scripts/rodar-tarefa.sh <profile> <task_key>` roda UMA tarefa (~35s) em vez do
job inteiro (~4,6min) — é `jobs run-now` com `only`.

**Entrega 6 concluída** (`.llm/prompt-06-agentes.md`): `src/gold/09-metricas-negocio.sql`
cria 6 views de negócio (`receita_mensal`, `ranking_marcas`,
`margem_por_categoria`, `clientes_em_risco` — **503 clientes, R$ 826.950/mês
parados** —, `efeito_lancamento` — só 47 dos 292 SKUs têm `data_lancamento` —,
`ruptura_por_marca`). `src/gold/10-auditoria-metadado.sql` quebra o job se uma
tabela/view da gold estiver sem COMMENT ou se faltar comentário em coluna do
fato ou das 6 views; grava `gold._auditoria_metadado` (achados) e
`gold._cobertura_metadado` (relatório, não quebra). **Cobertura: 100% nos 7
objetos do agente; dims, marts e `features_*` seguem parciais de propósito** —
não são data_source do Genie.

Genie space `Rota do Perfume - Comercial` (`01f1ae1462311688bc803a52a852d52c`),
como código em `resources/genie.genie_space.yml` +
`resources/comercial.geniespace.json`. **O JSON é gerado, não editado à mão:**
`python scripts/gerar-geniespace.py <profile>` (ids = md5 do conteúdo, listas
ordenadas). Texto das instruções em `docs/genie-instrucoes.md`.
**Armadilha medida da API: `instructions.text_instructions` aceita NO MÁXIMO UM
item** — os blocos vão concatenados.

**ML prompt 2 concluído** (`.llm/prompt-02-modelo.md`): `src/ml/12-modelo.py`.
Modelo `lakehouse_rotaperfume.gold.propensao_compra` v1, alias `@prod`
(`HistGradientBoostingClassifier`, semente 42). Tabelas novas:
`gold.score_propensao` (2.816 clientes, faixa em quartis),
`gold.modelo_metricas` (append, uma linha por treino) e
`gold.calibragem_holdout`. **Números medidos neste workspace:** AUC **0,8510**;
baselines recência **0,3908** (pior que a moeda — a intuição está *invertida*),
valor 0,6237, atraso_relativo **0,7184**; `lift_top200` **3,95×** (**80** dos
200 compram, contra 20 às cegas); feature nº 1 = `atraso_relativo`.
São um pouco abaixo dos do prompt (0,8817 / 86 / 4,25×), porque as features
deste workspace divergem em dois pontos: `gerou_pedido` é derivada de
`resultado = 'Pedido realizado'` (a coluna não existe em `silver.visitas`) e
`conversao_visita` usa todo o histórico, não só 90 dias. **A leitura da aula é
idêntica** — recência pior que a moeda, `atraso_relativo` como melhor regra
simples e como feature nº 1, e os 3 asserts passando.

Armadilhas confirmadas: `workspace.mkdirs()` antes de `set_experiment`;
`log_model(artifact_path=...)` (MLflow 2.22, não o `name=` do 3);
`predict_proba`, não `pyfunc.predict`; ordem de colunas de
`modelo.feature_names_in_`. `model-versions get-by-alias` devolve a versão mas
mostra `aliases: []` — **isso não é falha do alias**.

**ML prompt 3 concluído** (`.llm/prompt-03-fila-e-agente.md`): `src/ml/13-fila.sql`.
`gold.fila_semanal` — **200 contatos em 35 vendedores**, com `motivo` em
português e `sugestao` de produto. A ordem das operações é o ponto: filtra
carteira vigente + vendedor ativo (2.393 elegíveis) **antes** do `LIMIT 200`.
Quatro funções SQL no UC: `priorizar_carteira`, `contexto_cliente`,
`sugerir_produtos`, `checar_disponibilidade` — o `COMMENT` é o que diz ao
agente quando usar cada uma. Genie space agora com **13 tabelas**.

Três defeitos encontrados e corrigidos aqui, todos por inspeção do resultado:
1. **Ordem do `CASE` do motivo** — `comprou_lancamento` é o sinal mais *comum*
   (70% da base), não o mais raro: colocado cedo, dava 170 dos 200 contatos com
   a mesma frase. Ordem medida: atraso>3x (0) · atraso>1,5x (7) · grande (67) ·
   lançamento (177).
2. **`FORMAT_NUMBER` usa separador americano** — `R$ 238,539` lê como 238 reais
   em pt-BR. Envolver em `REPLACE`.
3. **Subquery escalar correlacionada em SELECT agregado** dá
   `SCALAR_SUBQUERY_IS_IN_GROUP_BY_OR_AGGREGATE_FUNCTION` — use CTE + CROSS JOIN.
   Sem isso, `marcas_preferidas` saía com marca repetida.

**Pendente do prompt 3:** o item 4 (página "Fila da semana" no dashboard) não
foi feito — `resources/dashboard-comercial.lvdash.json` não existe, porque a
entrega 5 ainda não foi feita. Fazer junto com o `.llm/prompt-05-dashboard.md`.

**O número que não pode mudar:** R$ 102.303.828,05 — idêntico na silver, no
`fato_vendas`, no `mart_vendas_por_vendedor` e no `mart_produto_performance`.
É o teste 1 e o teste 8; se mudar, o job para.

Fatos do ambiente que custaram tempo: **ANSI mode ligado** — `to_date()` sobre
data malformada aborta, use `try_to_date`; divisão por zero também aborta, use
`try_divide`. `SELECT * REPLACE (...)` dá `PARSE_SYNTAX_ERROR` neste DBSQL.
`sql_task` de arquivo aceita várias instruções separadas por `;`, mas **sua
saída no log do job vem vazia** — por isso os testes gravam numa tabela.

Os seis prompts estão em `.llm/`. **01 a 04 já foram corrigidos** para este
workspace; **05 e 06 ainda têm profile e caminho antigos**.

Valores reais deste ambiente — o `prompt_01.md` cita outros, de outro workspace:

| | prompt_01.md | real |
|---|---|---|
| profile | `projeto-dados-ia` | **`projetovendas`** |
| warehouse | `666be37e3fededf2` | **`a5b638ac09d4df5e`** |
| caminho | `aulas/aula-02-.../rotaperfume/` | **`LakehouseVendas/rotaperfume/`** |

O caminho nos prompts é escrito a partir de `projeto jornada/` — é de lá que
a turma cola. Trabalhando de dentro deste repositório, o bundle é só
`rotaperfume/`.

`lakehouse_lojaperfume` (catálogo da noite 1, feito clicando: sem COMMENT, sem
Volume) fica intacto — é o "ontem" do contraste da aula. O job `pipeline`
também é da noite 1 e não tem relação com este bundle.

## Comandos

Sempre a partir de `rotaperfume/`, e **sempre com `--profile`
explícito** (nunca deixe implícito):

```bash
uv sync --dev                                          # dependências locais
uv run pytest                                          # todos os testes
uv run pytest tests/test_x.py::test_y                  # um teste só
uv run ruff check . && uv run ruff format .            # lint (line-length 120)

databricks bundle validate --target dev --profile projetovendas
databricks bundle deploy   --target dev --profile projetovendas
databricks bundle run rotaperfume_pipeline --target dev --profile projetovendas
```

`pytest` usa Databricks Connect: `tests/conftest.py` abre uma `DatabricksSession`
real e cai para serverless (`DATABRICKS_SERVERLESS_COMPUTE_ID=auto`) se nenhum
compute for indicado. Ou seja, **teste local exige workspace acessível** — não
há modo offline. A fixture `load_fixture` lê JSON/CSV de `fixtures/`.

## Arquitetura pretendida

Fluxo em quatro estágios, cada um dono de uma camada:

```
dados/*.csv  →  Volume UC (bronze.raw)  →  bronze  →  silver  →  gold
   local          arquivo, byte a byte     tabela   limpo/conformado  métricas
```

- **Raw ≠ bronze.** Raw é *arquivo* dentro de `/Volumes/{catalog}/bronze/raw/{erp,crm}`;
  bronze é *tabela*. O Volume preserva o CSV como saiu do sistema de origem —
  é a resposta para "esse número veio de onde?".
- **Catálogo:** `lakehouse_rotaperfume`, com schemas `bronze`, `silver`, `gold`.
- **Job único:** `rotaperfume_pipeline` ganha uma tarefa por entrega
  (a primeira é `raw_conferencia`). Não crie um job por etapa.
- **Conferência de chegada:** a tarefa `raw_conferencia` grava
  `bronze._raw_arquivos` (sistema, arquivo, bytes, linhas, conferido_em) e
  **falha o job** se faltar arquivo ou algum vier vazio. Arquivo que não chega
  não dá erro — dá número menor com cara de número certo.

Os 10 arquivos esperados: `erp/` produtos, pedidos, itens_pedido, pagamentos,
estoque; `crm/` clientes, vendedores, carteira, oportunidades, visitas.
Chaves de junção: `sku`, `pedido_id`, `cliente_id`, `vendedor_id`.

## Restrições do ambiente (Databricks Free Edition)

Estas quatro já custaram tempo — não redescubra:

1. **Nunca configure cluster.** Tudo é serverless.
2. **Catálogo não sobe pelo bundle.** Com Default Storage ligado, a API do UC
   recusa `CREATE CATALOG` (`Metastore storage root URL does not exist`,
   400 INVALID_STATE). Crie por SQL em `scripts/criar-catalogo.sh`, antes do
   deploy, e deixe o motivo comentado no script.
3. **Sem `mode: development` no target dev.** Ele prefixa recursos com
   `[dev usuario]` — inclusive os **schemas do UC**, que virariam
   `dev_fulano_bronze` e quebrariam todo o SQL da aula.
4. **`databricks fs cp` exige o esquema `dbfs:`** no destino, mesmo sendo Volume
   do UC: `dbfs:/Volumes/lakehouse_rotaperfume/bronze/raw/erp`.

Ordem obrigatória no primeiro deploy: criar catálogo → `bundle deploy` (cria
schemas e Volume) → subir CSVs → `bundle run`.

## Convenções

- Notebooks Python em `src/` começam com `# Databricks notebook source` e
  recebem parâmetros via `dbutils.widgets` (ex.: `catalog`).
- Todo schema, volume e tabela leva `COMMENT` em português explicando seu papel
  em uma frase — é isso que documenta a camada no Catalog Explorer.
- Scripts em `scripts/` recebem o profile como **primeiro argumento, sem default**.
- YAML da entrega documenta o *porquê* das armadilhas em comentário; o
  `pipeline.job.yml` mantém no topo o desenho de como o job vai ficar ao fim das
  seis entregas.
- `rotaperfume/CLAUDE.md` é um stub que importa `AGENTS.md`
  (instrução do template para carregar a skill `databricks-core` antes de agir).
