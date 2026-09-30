# TRD — Especificação Técnica

Complementa o [PRD](01-PRD.md). Arquitetura visual em [03-ARQUITETURA.md](03-ARQUITETURA.md).

---

## 1. Stack

| Camada | Tecnologia | Por quê |
|---|---|---|
| Canal | WhatsApp (ver §2) | Onde a cliente já está |
| Orquestração | **n8n** (self-hosted) | Stack da Ampliize, AI Agent nativo, sub-workflows como ferramentas, fácil de ajustar sem deploy |
| LLM — agente | Claude Sonnet (`claude-sonnet-5-5`) | Melhor equilíbrio qualidade/latência para diálogo com ferramentas |
| LLM — tarefas leves | Claude Haiku (`claude-haiku-4-5-20251001`) | Classificação, resumo de handoff, extração em lote do histórico |
| Transcrição de áudio | Whisper (OpenAI) ou equivalente | Áudio é muito comum em salão |
| Banco / estado | **Supabase** (Postgres + pgvector) | Memória de conversa, base de conhecimento, logs, config |
| Buffer de mensagens | Tabela Supabase (MVP) / Redis (se volume crescer) | Agrupar mensagens em rajada |
| Sistema de gestão | **API Belasis** | Fonte da verdade de clientes, agenda, serviços |
| Painel (fase 2) | Lovable + Supabase | Editor de KB e métricas |

## 2. Decisão de canal WhatsApp (decidir até 01/10)

Restrição central: **o Belasis já usa uma extensão ligada ao WhatsApp do salão**. O bot não pode quebrar isso.

| Opção | Como funciona | Prós | Contras |
|---|---|---|---|
| **A. Cloud API oficial (Meta) em modo coexistência** ✅ recomendada | Número continua no app WhatsApp Business **e** fica conectado à Cloud API ao mesmo tempo | Oficial (sem risco de ban), webhooks estáveis, mensagens do app aparecem como "echo" (detecta humano assumindo) | Onboarding via BSP/Meta (1–3 dias), templates pagos para mensagens fora da janela de 24 h, precisa confirmar se a extensão Belasis continua funcionando com o número em coexistência |
| **B. Evolution API (WhatsApp Web / Baileys)** | Conecta como mais um "aparelho vinculado" do número | Setup em horas, convive com WhatsApp Web + extensão (é só mais um dispositivo), sem custo por mensagem | Não oficial → risco de banimento; sessão pode cair; depende de manutenção |
| C. Número novo só para o bot | Separado do número atual | Zero conflito | Clientes já têm o número atual salvo — pior experiência |

**Recomendação:** iniciar o onboarding da **opção A** no dia 01/10 e, em paralelo, subir a **opção B** em homologação para não travar o desenvolvimento. O n8n fica atrás de uma camada `channel_adapter` (sub-workflow) que normaliza as mensagens — trocar de A para B (ou vice-versa) muda só esse adaptador.

### Formato normalizado de mensagem (contrato do adapter)

```json
{
  "message_id": "wamid.xxx",
  "phone": "5511999998888",
  "push_name": "Juliana",
  "from_me": false,
  "type": "text | audio | image | document | sticker | reaction",
  "text": "Quero fazer progressiva de novo",
  "media_url": null,
  "timestamp": "2026-10-03T14:02:11-03:00",
  "raw": { }
}
```

## 3. Fluxo de uma mensagem

```
webhook canal
 → channel_adapter (normaliza)
 → filtros: ignora grupo/status/equipe/duplicada (message_id já visto)
 → se from_me = true (humano respondeu pelo celular) → marca conversa "humano_assumiu" até now()+N h → FIM
 → se conversa em "humano_assumiu" ou "aguardando_humano" → só loga → FIM
 → mídia: áudio → transcreve; imagem → guarda URL p/ visão
 → buffer: grava em msg_buffer e espera 8 s; se chegou outra mensagem da mesma conversa, esta execução encerra (a última execução processa o lote)
 → carrega contexto (determinístico, sem LLM):
      • cliente Belasis por telefone (cache 10 min)
      • próximos agendamentos da cliente
      • últimos 5 atendimentos (serviço, profissional, data)
      • memória da conversa (últimas 30 mensagens)
 → AI Agent (Claude) com ferramentas (§5)
 → pós-processamento: quebra em até 3 mensagens curtas, delay de digitação
 → envia pelo channel_adapter
 → loga (mensagens, tool calls, tokens, latência)
```

**Identidade é plumbing, não LLM:** o telefone e o `cliente_id` Belasis entram nas ferramentas direto do contexto da execução — nunca via `$fromAI()`. O agente não consegue consultar ou agendar para outra pessoa.

## 4. Pipeline de conhecimento a partir do histórico do WhatsApp

Aplicando o padrão `acquire → prepare → process → parse → render` (etapas determinísticas separadas da etapa LLM, cada uma idempotente e com saída em arquivo/tabela).

| Etapa | Entrada → Saída | Como |
|---|---|---|
| **1. Acquire** | Export `.txt`/`.zip` das conversas (WhatsApp → Exportar conversa, sem mídia) ou histórico via Evolution API → `raw/{conversa}.txt` | Pedir ao cliente 50–150 conversas representativas dos últimos 3–6 meses |
| **2. Prepare** | `raw` → `prepared/{conversa}.json` | Parser do formato de export; separa falas salão × cliente; **anonimiza** (nome → `[CLIENTE]`, telefone, CPF, endereço); descarta conversas pessoais |
| **3. Process** | `prepared` → `extracted/{conversa}.json` | Haiku extrai em JSON: perguntas feitas, resposta do salão, intenção, preços citados, políticas citadas, frases típicas do tom de voz |
| **4. Parse / consolidar** | `extracted/*` → `kb_draft.json` | Agrupa perguntas semelhantes, resolve conflitos (preço mais recente vence), marca itens sem fonte |
| **5. Render** | `kb_draft.json` → tabela `kb_itens` + `docs/tom-de-voz.md` + casos de teste | **Revisão humana obrigatória** (Karol/Ampliize) antes de ativar cada item |

Produtos do pipeline:
1. **Base de conhecimento** (FAQ + políticas) → `kb_itens`.
2. **Guia de tom de voz** com 10–15 exemplos reais anonimizados → entra no system prompt (few-shot).
3. **Conjunto de avaliação**: 40–60 perguntas reais com resposta esperada → suíte de regressão (§9).

Preço e disponibilidade **não** vêm do histórico (ficam desatualizados) — vêm sempre do Belasis em tempo real. O histórico serve para FAQ, políticas e tom.

## 5. Ferramentas do agente

Princípios (skill *tool-design*): poucas ferramentas, sem sobreposição, nome verbo+objeto, descrição diz **o que faz / quando usar / o que retorna**, erros acionáveis, identidade plumbada. Cada ferramenta é um **sub-workflow n8n** (`toolWorkflow`) que chama a API Belasis.

| Ferramenta | Faz | Parâmetros do agente (`$fromAI`) | Parâmetros plumbados |
|---|---|---|---|
| `buscar_servicos` | Lista serviços com duração, preço/faixa e profissionais que fazem | `termo` (ex.: "progressiva") | — |
| `consultar_horarios` | Horários livres para um serviço, opcionalmente com profissional, em um período | `servico_id`, `profissional_id?`, `data_inicio`, `data_fim?` (padrão +14 dias), `turno?` (manha/tarde/noite) | `unidade_id` |
| `agendar_horario` | Cria agendamento no Belasis | `servico_id`, `profissional_id`, `inicio` (ISO), `confirmacao_cliente` (texto literal do "sim") | `cliente_id`, `telefone`, `conversa_id` |
| `alterar_agendamento` | Remarca ou cancela agendamento futuro **da própria cliente** | `agendamento_id`, `acao` (remarcar/cancelar), `novo_inicio?`, `confirmacao_cliente` | `cliente_id` |
| `consultar_base_conhecimento` | Busca FAQ/políticas aprovadas | `pergunta` | — |
| `transferir_para_humano` | Pausa o bot na conversa e notifica equipe com resumo | `motivo` (enum: pedido_cliente, reclamacao, fora_escopo, orcamento_visual, erro_sistema, incerteza), `resumo` | `conversa_id`, `telefone` |

O **contexto da cliente** (cadastro, histórico, próximos agendamentos) **não é ferramenta**: é carregado antes do agente e injetado no prompt. Isso resolve o caso "mesma profissional da última vez" sem uma chamada extra e sem o agente precisar decidir buscar.

### Exemplo de descrição (vai no n8n)

```
consultar_horarios
Busca horários LIVRES na agenda do Belasis para um serviço.
Use quando a cliente quer marcar/remarcar ou pergunta "tem horário?".
Se a cliente quer "a mesma profissional", passe o profissional_id do histórico dela (contexto).
Parâmetros:
 - servico_id: id retornado por buscar_servicos ou pelo histórico (ex.: "srv_123")
 - profissional_id: opcional; omita para qualquer profissional habilitada
 - data_inicio: AAAA-MM-DD, nunca no passado. Padrão: hoje
 - data_fim: AAAA-MM-DD, no máx. 30 dias após data_inicio. Padrão: +14 dias
 - turno: opcional "manha" | "tarde" | "noite"
Retorna: até 6 slots [{inicio, fim, profissional_id, profissional_nome}], ordenados por data.
Erros:
 - SEM_HORARIOS: nenhum slot no período → ofereça ampliar período ou outra profissional
 - SERVICO_INVALIDO: chame buscar_servicos para obter o id correto
 - BELASIS_INDISPONIVEL: peça desculpas e use transferir_para_humano(motivo=erro_sistema)
```

### Guardas nas ferramentas de escrita (determinísticas, dentro do sub-workflow)

- `agendar_horario` revalida disponibilidade imediatamente antes de criar (evita conflito com agendamento feito pela recepção no meio da conversa).
- Rejeita `inicio` no passado ou fora do horário de funcionamento.
- `alterar_agendamento` confere que `agendamento_id` pertence ao `cliente_id` plumbado.
- Idempotência: chave `conversa_id + servico_id + inicio` — repetir a chamada não duplica agendamento.
- Cliente sem cadastro no Belasis → sub-workflow cria cadastro mínimo (nome + telefone) antes de agendar (confirmar se a API permite; senão → humano).

## 6. Prompt do agente (estrutura)

```
[Papel] Assistente virtual do salão Cabelos by Karol no WhatsApp.
[Data/hora] {{ $now }} (America/Sao_Paulo) — horário de funcionamento: ...
[Cliente] nome, é cliente desde, últimos atendimentos (serviço/profissional/data), próximos agendamentos
[Regras invioláveis] PRD §6 (nunca inventar preço/horário; confirmar antes de escrever; reclamação → humano...)
[Fluxo de agendamento] entender serviço → profissional (preferência/histórico) → consultar_horarios → oferecer ≤3 opções → resumo → "sim" explícito → agendar_horario
[Tom de voz] diretrizes + 10–15 exemplos reais anonimizados (pipeline §4)
[Formato] mensagens curtas, até 3 blocos, sem markdown pesado (WhatsApp usa *negrito*)
```

Configuração do nó AI Agent: `maxIterations: 15`, memória Postgres (`memoryPostgresChat`) com `sessionKey = conversa_id` e janela de 30 mensagens, temperatura baixa.

## 7. Modelo de dados (Supabase)

```sql
create table conversas (
  id uuid primary key default gen_random_uuid(),
  telefone text not null unique,
  belasis_cliente_id text,
  nome text,
  status text not null default 'bot'          -- bot | humano_assumiu | aguardando_humano
    check (status in ('bot','humano_assumiu','aguardando_humano')),
  pausado_ate timestamptz,
  ultima_msg_em timestamptz,
  criado_em timestamptz default now()
);

create table mensagens (
  id bigint generated always as identity primary key,
  conversa_id uuid references conversas(id),
  message_id text unique,                      -- dedupe do webhook
  direcao text check (direcao in ('in','out')),
  autor text check (autor in ('cliente','bot','humano')),
  tipo text,
  texto text,
  media_url text,
  criado_em timestamptz default now()
);

create table msg_buffer (                       -- agrupamento de rajadas
  conversa_id uuid references conversas(id),
  message_id text primary key,
  texto text,
  recebido_em timestamptz default now()
);

create table execucoes_agente (                 -- observabilidade
  id bigint generated always as identity primary key,
  conversa_id uuid references conversas(id),
  entrada text,
  saida text,
  tool_calls jsonb,
  tokens_in int, tokens_out int,
  latencia_ms int,
  erro text,
  criado_em timestamptz default now()
);

create table acoes_belasis (                    -- auditoria de escrita
  id bigint generated always as identity primary key,
  conversa_id uuid references conversas(id),
  acao text,                                   -- criar | remarcar | cancelar | criar_cliente
  payload jsonb,
  resposta jsonb,
  confirmacao_cliente text,
  idempotency_key text unique,
  sucesso boolean,
  criado_em timestamptz default now()
);

create table handoffs (
  id bigint generated always as identity primary key,
  conversa_id uuid references conversas(id),
  motivo text,
  resumo text,
  atendido_por text,
  resolvido_em timestamptz,
  criado_em timestamptz default now()
);

create table kb_itens (
  id bigint generated always as identity primary key,
  categoria text,                              -- servico | politica | local | pagamento | geral
  pergunta text,
  resposta text,
  fonte text,                                  -- historico_whatsapp | cliente | belasis
  aprovado boolean default false,
  embedding vector(1536),
  atualizado_em timestamptz default now()
);

create table config_bot (
  chave text primary key,                       -- pausa_humano_horas, janela_buffer_s, dias_busca_padrao, numeros_equipe, ...
  valor jsonb
);
```

RLS habilitado em todas as tabelas; acesso só via service role do n8n (e, na fase 2, papel autenticado do painel).

Base de conhecimento: no MVP com poucas dezenas de itens, `consultar_base_conhecimento` pode simplesmente retornar todos os itens aprovados da categoria (sem vetor). pgvector entra só se a base passar de ~100 itens.

## 8. Contrato necessário da API Belasis (validar em 01/10)

| Necessidade | Endpoint esperado | Usado em |
|---|---|---|
| Buscar cliente por telefone | `GET /clientes?telefone=` | Contexto |
| Histórico de atendimentos da cliente | `GET /clientes/{id}/atendimentos` | Contexto (F3) |
| Próximos agendamentos da cliente | `GET /agendamentos?cliente_id=&de=hoje` | Contexto, F6 |
| Listar serviços (preço, duração) | `GET /servicos` | `buscar_servicos` |
| Profissionais e serviços que executam | `GET /profissionais` | `buscar_servicos`, `consultar_horarios` |
| Disponibilidade | `GET /agenda/disponibilidade?servico=&profissional=&de=&ate=` | `consultar_horarios` |
| Criar agendamento | `POST /agendamentos` | `agendar_horario` |
| Remarcar / cancelar | `PATCH` / `DELETE /agendamentos/{id}` | `alterar_agendamento` |
| Criar cliente | `POST /clientes` | Cliente nova |
| Webhooks (opcional) | agendamento criado/alterado | Invalidar cache, lembretes (fase 2) |

Para cada endpoint registrar: autenticação, formato de telefone (com/sem 55/9º dígito), fuso horário, paginação, rate limit, códigos de erro. **Se disponibilidade não existir pronta**, calcular no sub-workflow: expediente da profissional − agendamentos existentes − duração do serviço.

Normalização de telefone: armazenar sempre E.164 sem `+` (`5511999998888`) e tentar variações com/sem 9º dígito na busca.

## 9. Qualidade e avaliação

- **Suíte de regressão** (≥ 40 casos do pipeline §4 + casos sintéticos): executada antes de cada mudança de prompt/modelo. Critérios: ferramenta certa chamada, nenhum dado inventado, confirmação antes de escrita, tom adequado.
- **Checagens determinísticas** em todo log: escrita no Belasis sem `confirmacao_cliente` = alerta; resposta com R$ que não veio de ferramenta/KB = alerta.
- **Revisão humana** diária de 20 conversas nos primeiros 7 dias.
- Casos obrigatórios: mesma profissional; profissional sem horário; cliente nova; áudio; mensagens em rajada; reclamação; remarcar em cima da hora; pergunta fora do escopo; tentativa de agendar para outra pessoa; Belasis fora do ar.

## 10. Erros e contingência

| Falha | Comportamento |
|---|---|
| Belasis timeout/5xx | 2 retries com backoff; depois mensagem "estou com instabilidade para ver a agenda, já chamei alguém da equipe" + `transferir_para_humano(erro_sistema)` |
| LLM falha | Retry 1x; depois mensagem padrão + handoff |
| Webhook duplicado | Dedupe por `message_id` |
| Parse do agente falha | Não envia nada estranho à cliente; loga e usa mensagem de contingência |
| Sessão WhatsApp cai (opção B) | Alerta imediato (Slack/WhatsApp da Ampliize) via Error Workflow do n8n |

## 11. Custo (estimativa a preencher)

```
custo_mes ≈ conversas_mes × turnos_por_conversa × (tokens_in × preço_in + tokens_out × preço_out) × 1,25
```

Premissas iniciais: ~6–8 k tokens de entrada por turno (prompt + contexto + memória + ferramentas), ~300 tokens de saída, ~6 turnos por conversa. Usar prompt caching no system prompt fixo (tom de voz + regras) para reduzir custo de entrada. Preencher com volume real de conversas/mês do salão e tabela de preços vigente.

## 12. Segurança e LGPD

- Base legal: execução de contrato/legítimo interesse para atendimento; aviso na primeira mensagem de que é atendimento automatizado.
- Histórico do WhatsApp usado no pipeline é anonimizado antes de ir ao LLM; arquivos brutos apagados após gerar a KB.
- Secrets no n8n Credentials / Supabase Vault. Nada de chave em prompt ou log.
- Retenção: mensagens 180 dias (configurável), auditoria de ações 5 anos.
- Pedido de exclusão de dados → rotina manual documentada.
