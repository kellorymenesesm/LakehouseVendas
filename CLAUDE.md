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
**10 tarefas**: `raw_conferencia` → `bronze_ingestao` → 4 silver em paralelo →
`gold_dimensoes` → `gold_fato_vendas` → `gold_marts` → `testes`.
Agendado 6h, PAUSED. Próxima: entrega 5, o dashboard (`.llm/prompt-05-dashboard.md`).

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
