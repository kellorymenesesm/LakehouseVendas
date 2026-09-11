#!/usr/bin/env python
"""Gera resources/comercial.geniespace.json -- o Genie space como codigo.

    python scripts/gerar-geniespace.py <profile>

Por que um gerador, e nao um JSON escrito a mao: a API do Genie exige um `id`
de 32 hexadecimais minusculos em CADA pergunta e instrucao, e exige que as
listas venham ORDENADAS. Feito a mao, alguem gera id aleatorio, o redeploy
recria as perguntas e o diff do Git enche de ruido sem nada ter mudado.

Aqui o id e o md5 do proprio conteudo. Mesmo texto, mesmo id, para sempre:
mudar a pergunta muda o id -- que e exatamente o comportamento certo, porque
a pergunta passou a ser outra.

As quatro regras da API que fazem o deploy falhar se forem ignoradas:
  a) data_sources.tables ordenado por identifier
  b) column_configs de cada tabela ordenado por column_name
  c) todo id com 32 hex minusculos, sem hifen
  d) sample_questions, text_instructions e example_question_sqls ordenados por id

O formato foi lido de um space real com
`databricks bundle generate genie-space --existing-id <id>`: `question`,
`content` e `sql` sao LISTAS de linhas, nao strings.
"""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
from pathlib import Path

CATALOGO = "lakehouse_rotaperfume"
DESTINO = Path(__file__).resolve().parent.parent / "resources" / "comercial.geniespace.json"

# As 6 views de negocio + o fato + as 4 dimensoes. A bronze e a silver NAO
# entram: o agente da noite 1 errou justamente por ler tabela sem limpeza.
OBJETOS = [
    # A fila e o score entram no prompt 3: e a tabela que o vendedor pergunta
    # por "quem eu ligo essa semana".
    "fila_semanal",
    "score_propensao",
    "receita_mensal",
    "ranking_marcas",
    "margem_por_categoria",
    "clientes_em_risco",
    "efeito_lancamento",
    "ruptura_por_marca",
    "fato_vendas",
    "dim_cliente",
    "dim_produto",
    "dim_vendedor",
    "dim_calendario",
]

# ---------------------------------------------------------------------------
# As instrucoes. Espelham docs/genie-instrucoes.md -- aquele arquivo e a fonte
# que um humano le, este bloco e o que vai para dentro do space.
# ---------------------------------------------------------------------------
INSTRUCOES = [
    """CONTEXTO
A Rota do Perfume e uma distribuidora B2B de perfumaria arabe. Ela NAO vende ao consumidor final: vende para o varejo -- lojas de shopping, quiosques, perfumarias de bairro e revendedoras autonomas. Todo "cliente" nesta base e uma empresa compradora, nunca uma pessoa fisica.
O periodo coberto vai de 2024-09-01 a 2026-08-31. O dia de referencia do dataset e 2026-08-31: use essa data como "hoje" e NUNCA use current_date(), que e posterior ao fim dos dados e inflaria qualquer calculo de recencia.
Use apenas tabelas e views do schema gold. A bronze e texto puro sem limpeza e a silver e camada intermediaria: nenhuma das duas responde pergunta de negocio, mesmo que o nome da coluna pareca certo.""",
    """REGRA DE SAZONALIDADE -- A MAIS IMPORTANTE
O pico da distribuidora e o mes ANTERIOR a data comemorativa, porque o varejo compra antes para ter estoque na data.
Picos: abril (Dia das Maes, em maio), junho (Namorados) e outubro (Black Friday, em novembro).
Vales: dezembro e janeiro. O varejo ja se abasteceu nos picos anteriores e passa o comeco do ano escoando estoque.
Dezembro e janeiro serem baixos e SAUDAVEL e ESPERADO. Nunca chame isso de queda, de problema ou de mes ruim. Se perguntarem "dezembro foi ruim?", a resposta correta e NAO: e vale de setor, por desenho do calendario do varejo, nao desempenho da empresa.
A view gold.receita_mensal tem a coluna mes_pico_setor exatamente para isso. Consulte essa coluna antes de qualificar qualquer mes como bom ou ruim, e compare um mes sempre com o MESMO mes do ano anterior, nunca com o mes imediatamente anterior.""",
    """GLOSSARIO
Ruptura: produto com saldo zero no snapshot diario de estoque -- existe no catalogo mas nao esta disponivel para venda. Media da empresa: cerca de 11,7% das fotos de estoque.
Carteira: o conjunto de clientes sob responsabilidade de um vendedor.
Oportunidade: negocio em negociacao no CRM, com etapa, valor estimado e desfecho (ganha, perdida, ou nenhuma das duas = ainda em aberto).
Devolucao: item que voltou. Entra no fato com quantidade e receita NEGATIVAS, e nao e excluido.
SKU: codigo do produto. Sao 292 no catalogo.
Segmento: tipo de ponto de venda do cliente (loja de shopping, quiosque, revendedora autonoma).
Atingimento de meta: receita do vendedor no mes dividida pela meta do mesmo mes, em %. Pronto em mart_vendas_por_vendedor.atingimento_pct.
Curva ABC: classificacao do produto por participacao na receita do mes. A e o topo, C e a cauda. Pronta em mart_produto_performance.curva_abc.""",
    """REGRAS DE CALCULO
Receita: SUM(receita) no fato. E LIQUIDA -- a devolucao ja entra com sinal negativo. Para o bruto vendido, filtre devolucao = false. A diferenca entre os dois e cerca de R$ 1,26 milhao no periodo.
Margem: SUM(margem) = receita menos custo do produto. NAO inclui frete, comissao de vendedor nem impostos. Diga isso sempre que reportar margem como lucro.
Margem %: margem dividida pela receita do mesmo recorte. Nunca some percentuais de margem entre si; recalcule a partir das somas.
Ticket medio: receita dividida por COUNT(DISTINCT pedido_id), nunca pelo numero de linhas -- o fato esta no grao de ITEM, e um pedido tem cerca de 7 itens.
Churn / cliente em risco: mais de 90 dias sem pedido, contados a partir de 2026-08-31. Sao 503 clientes, prontos em gold.clientes_em_risco. A coluna receita_media_mensal e NULL para quem comprou uma unica vez -- sem dois pedidos nao ha janela para medir ritmo, e esses nao devem entrar em soma de receita perdida.
Pedido cancelado nao esta no fato: foi excluido na modelagem, nao tente filtrar por status de cancelamento.""",
    """REGRA DE OURO -- NAO INVENTE
Use SEMPRE as tabelas e funcoes deste espaco. Nunca invente numero, nome de cliente ou quantidade de estoque.
Se a resposta nao estiver nos dados deste espaco, diga que nao esta -- nao estime, nao arredonde de cabeca e nao complete com exemplo plausivel.
Quantidade de estoque vem SEMPRE de gold.checar_disponibilidade ou de gold.ruptura_por_marca, nunca de memoria: o saldo muda toda semana.""",
    """A FILA DA SEMANA
gold.fila_semanal tem as 200 ligacoes da semana, ja ordenadas e distribuidas por vendedor. Uma linha por contato, com o motivo escrito em portugues na coluna motivo e o produto a oferecer na coluna sugestao.
Quando perguntarem "quem eu ligo essa semana", filtre por vendedor e ordene por ordem -- ou chame gold.priorizar_carteira(nome_do_vendedor, quantos).
Quando perguntarem POR QUE um cliente esta na lista, leia a coluna motivo: ela ja traz os numeros do cliente. Nao invente uma explicacao nova.
A fila e GLOBAL por score, nao cota por vendedor: um vendedor pode ter 10 contatos e outro apenas 1, e isso significa que a carteira do primeiro esta mais quente -- nao que ele seja melhor vendedor.
gold.score_propensao tem a nota de TODOS os clientes, nao so dos 200. O score e probabilidade de compra nos proximos 7 dias, de 0 a 1: e ordenacao, nao garantia.
As quatro funcoes do espaco: gold.priorizar_carteira (para quem ligar), gold.contexto_cliente (quem e o cliente), gold.sugerir_produtos (o que oferecer) e gold.checar_disponibilidade (tem em estoque?).""",
    """ONDE PROCURAR CADA PERGUNTA
Quem eu ligo essa semana -> gold.fila_semanal, ou gold.priorizar_carteira(vendedor, quantos)
Por que este cliente esta na minha lista -> a coluna motivo de gold.fila_semanal
Qual a nota de um cliente -> gold.score_propensao
Evolucao mes a mes -> gold.receita_mensal
Quais marcas mais venderam -> gold.ranking_marcas
Qual categoria da mais margem -> gold.margem_por_categoria
Quem parou de comprar -> gold.clientes_em_risco
O lancamento vendeu de verdade -> gold.efeito_lancamento
Que marca falta na prateleira -> gold.ruptura_por_marca
Vendedor contra a meta -> gold.mart_vendas_por_vendedor
Produto curva A no mes -> gold.mart_produto_performance
Quanto ha a receber e com que atraso -> gold.mart_financeiro_recebimento
Qualquer corte que as views nao cobrem -> gold.fato_vendas com as dimensoes.
Prefira a view ao fato quando existir uma que responda a pergunta: ela ja traz a regra de negocio embutida. Quando a resposta depender de uma escolha sua (janela de tempo, recorte, definicao), diga qual escolha voce fez ANTES do numero.""",
]

# ---------------------------------------------------------------------------
# Perguntas de exemplo com SQL -- todas rodadas no warehouse antes de entrar
# aqui. Exemplo com SQL errado ensina o agente a errar igual.
# ---------------------------------------------------------------------------
EXEMPLOS = [
    (
        "Quem eu ligo essa semana?",
        """SELECT vendedor,
       ordem,
       razao_social,
       cidade,
       ROUND(score, 3) AS score,
       motivo,
       sugestao
FROM lakehouse_rotaperfume.gold.fila_semanal
ORDER BY vendedor, ordem""",
    ),
    (
        "Por que este cliente esta na minha lista?",
        """SELECT razao_social,
       vendedor,
       ordem,
       ROUND(score, 3) AS score,
       faixa,
       motivo
FROM lakehouse_rotaperfume.gold.fila_semanal
ORDER BY score DESC""",
    ),
    (
        "Quais marcas mais venderam nos ultimos 6 meses?",
        """SELECT marca,
       ROUND(SUM(receita), 2) AS receita
FROM lakehouse_rotaperfume.gold.fato_vendas
WHERE data_pedido >= ADD_MONTHS(DATE'2026-08-31', -6)
GROUP BY marca
ORDER BY receita DESC""",
    ),
    (
        "Quais clientes pararam de comprar, e quanta receita por mes parou junto?",
        """SELECT razao_social,
       cidade,
       uf,
       dias_sem_comprar,
       receita_media_mensal
FROM lakehouse_rotaperfume.gold.clientes_em_risco
ORDER BY receita_media_mensal DESC NULLS LAST""",
    ),
    (
        "Dezembro foi um mes ruim?",
        """SELECT ano,
       mes,
       nome_mes,
       mes_pico_setor,
       receita
FROM lakehouse_rotaperfume.gold.receita_mensal
WHERE mes IN (10, 11, 12, 1)
ORDER BY ano, mes""",
    ),
    (
        "Qual categoria da mais margem?",
        """SELECT categoria,
       receita,
       margem,
       margem_pct
FROM lakehouse_rotaperfume.gold.margem_por_categoria
ORDER BY margem_pct DESC""",
    ),
    (
        "Quais marcas mais faltam na prateleira?",
        """SELECT marca,
       snapshots,
       snapshots_em_ruptura,
       ruptura_pct
FROM lakehouse_rotaperfume.gold.ruptura_por_marca
ORDER BY ruptura_pct DESC""",
    ),
    (
        "Os produtos lancados venderam de verdade, ou so enquanto eram novidade?",
        """SELECT descricao,
       marca,
       data_lancamento,
       receita_120d,
       receita_apos_120d,
       pct_nos_120d
FROM lakehouse_rotaperfume.gold.efeito_lancamento
ORDER BY receita_120d DESC""",
    ),
]

PERGUNTAS_DE_AMOSTRA = [
    "Quem eu ligo essa semana?",
    "Por que este cliente esta no topo da minha lista?",
    "Quais marcas mais venderam nos ultimos 6 meses?",
    "Quem parou de comprar, e quanto isso custa por mes?",
    "Dezembro foi um mes ruim?",
    "Qual categoria da mais margem, e qual so da volume?",
    "Quais marcas mais ficam em ruptura?",
    "Qual vendedor bateu a meta no ultimo mes?",
]


def texto_das_instrucoes() -> str:
    """Os blocos de INSTRUCOES concatenados num unico texto."""
    return "\n\n".join(bloco.strip() for bloco in INSTRUCOES)


def identificador(texto: str) -> str:
    """32 hexadecimais minusculos, derivados do conteudo. Nunca aleatorio."""
    return hashlib.md5(texto.encode("utf-8")).hexdigest()


def em_linhas(texto: str) -> list[str]:
    """A API guarda texto como LISTA de linhas, com o \\n preservado."""
    linhas = texto.split("\n")
    return [linha + "\n" for linha in linhas[:-1]] + [linhas[-1]]


def colunas_da_gold(profile: str) -> dict[str, list[tuple[str, str]]]:
    """Le information_schema no workspace: nome e tipo de cada coluna da gold."""
    lista = "', '".join(OBJETOS)
    sql = (
        "SELECT table_name, column_name, data_type "
        f"FROM {CATALOGO}.information_schema.columns "
        f"WHERE table_schema = 'gold' AND table_name IN ('{lista}') "
        "ORDER BY table_name, column_name"
    )
    saida = subprocess.run(
        ["databricks", "experimental", "aitools", "tools", "query", sql, "--profile", profile],
        capture_output=True,
        text=True,
        encoding="utf-8",
        check=True,
    ).stdout

    por_tabela: dict[str, list[tuple[str, str]]] = {}
    for linha in json.loads(saida):
        # Coluna tecnica nao e oferecida ao agente: _processado_em nao responde
        # pergunta de negocio nenhuma, e so serve para ele errar a data.
        if linha["column_name"].startswith("_"):
            continue
        por_tabela.setdefault(linha["table_name"], []).append(
            (linha["column_name"], linha["data_type"])
        )
    return por_tabela


def montar(profile: str) -> dict:
    colunas = colunas_da_gold(profile)

    faltando = [o for o in OBJETOS if o not in colunas]
    if faltando:
        raise SystemExit(
            f"objetos ausentes na gold: {', '.join(faltando)}\n"
            "rode antes: bash scripts/rodar-tarefa.sh <profile> metricas_de_negocio"
        )

    tabelas = []
    for objeto in OBJETOS:
        configs = [
            {
                "column_name": nome,
                # entity matching so faz sentido em texto: e o que deixa o
                # agente casar "Layali" com um valor da coluna marca.
                **({"enable_entity_matching": True} if tipo.upper() == "STRING" else {}),
                "enable_format_assistance": True,
            }
            for nome, tipo in sorted(colunas[objeto])  # regra (b)
        ]
        tabelas.append(
            {"column_configs": configs, "identifier": f"{CATALOGO}.gold.{objeto}"}
        )

    return {
        "config": {
            "sample_questions": sorted(  # regra (d)
                (
                    {"id": identificador(p), "question": em_linhas(p)}
                    for p in PERGUNTAS_DE_AMOSTRA
                ),
                key=lambda x: x["id"],
            )
        },
        "data_sources": {"tables": sorted(tabelas, key=lambda t: t["identifier"])},  # regra (a)
        "instructions": {
            "example_question_sqls": sorted(
                (
                    {
                        "id": identificador(pergunta),
                        "question": em_linhas(pergunta),
                        "sql": em_linhas(sql),
                    }
                    for pergunta, sql in EXEMPLOS
                ),
                key=lambda x: x["id"],
            ),
            # ARMADILHA MEDIDA DA API: text_instructions aceita NO MAXIMO UM
            # item -- "Invalid export proto: instructions.text_instructions
            # must contain at most one item" (400). Os blocos existem separados
            # em INSTRUCOES so para serem legiveis aqui; vao juntos para la.
            "text_instructions": [
                {
                    "content": em_linhas(texto_das_instrucoes()),
                    "id": identificador(texto_das_instrucoes()),
                }
            ],
        },
        "version": 2,
    }


def main() -> None:
    if len(sys.argv) != 2:
        print("uso: python scripts/gerar-geniespace.py <profile>", file=sys.stderr)
        print("     o profile nao tem default de proposito -- sempre explicito.", file=sys.stderr)
        raise SystemExit(1)

    espaco = montar(sys.argv[1])
    DESTINO.write_text(
        json.dumps(espaco, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )

    tabelas = espaco["data_sources"]["tables"]
    print(f"gravado: {DESTINO.relative_to(DESTINO.parent.parent)}")
    print(f"  tabelas .............: {len(tabelas)}")
    print(f"  colunas .............: {sum(len(t['column_configs']) for t in tabelas)}")
    print(f"  instrucoes ..........: {len(espaco['instructions']['text_instructions'])}")
    print(f"  exemplos com SQL ....: {len(espaco['instructions']['example_question_sqls'])}")
    print(f"  perguntas de amostra : {len(espaco['config']['sample_questions'])}")


if __name__ == "__main__":
    main()
