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

## 2. Canal WhatsApp — DECIDIDO: API não oficial (Evolution API / WhatsApp Web)

Decisão (30/09): usar **API não oficial** conectada como *aparelho vinculado* do número atual do salão. Ela convive com a extensão Belasis (que também é um aparelho vinculado) sem migrar o número. A API já está disponível, mas **só será conectada ao número de produção no piloto (07/10)**. Até lá, desenvolvimento em número de teste.

O n8n fica atrás de um `channel_adapter` (sub-workflow) que normaliza as mensagens — se um dia migrarmos para a Cloud API oficial, muda só o adaptador.

### 2.1 Regras de uso responsável (anti-banimento)

O risco de banimento vem de comportamento de robô/spam. Regras obrigatórias, implementadas no `WA · Enviar mensagem` e em `config_bot`:

| # | Regra | Implementação |
|---|---|---|
| R1 | **Só responder**, nunca iniciar conversa no MVP | Envio bloqueado se não houver mensagem recebida da cliente nas últimas 24 h |
| R2 | Sem disparo em massa, sem mensagens idênticas em série | Nenhum workflow de broadcast; lembretes (fase 2) só para quem tem agendamento, com limite diário e texto variado |
| R3 | Comportamento humano no envio | Marcar como lida → presença "digitando" → delay proporcional ao tamanho (≈ 40 ms/caractere, mín. 2 s, máx. 8 s, com jitter aleatório) |
| R4 | Limite de vazão | Máx. 1 mensagem a cada 3 s por número e ~20/min no total; fila no Supabase se exceder |
| R5 | Mensagens curtas e poucas | Máx. 3 blocos por resposta; nada de links na primeira resposta a um número novo |
| R6 | Sessão estável | Uma única instância, servidor/IP fixo, sem reconectar em loop; celular do salão ligado e com internet (aparelho vinculado cai após ~14 dias sem o celular online) |
| R7 | Respeitar aparelhos vinculados | Limite de 4 aparelhos: extensão Belasis + API + reserva. Ninguém desconecta a API pelo celular |
| R8 | Monitoramento e kill switch | Alerta imediato em desconexão/QR pedido/erro de envio; flag `bot_ativo` em `config_bot` desliga todo envio na hora |
| R9 | Ignorar grupos, status, listas de transmissão e números da equipe | Filtro no `WA · Entrada` |
| R10 | Opt-out | Cliente que pedir "não quero falar com robô" → handoff e bot desativado para aquele número |

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
| `consultar_horarios` | Horários livres para um serviço, opcionalmente com profissional, em um período | `servico_id`, `profissional_id?`, `data_inicio`, `data_fim?` (padrão +14 dias), `turno?` (manha/tarde/noite) | — |
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

✅ Implementado e aplicado no projeto Supabase "cabelos by karol". Detalhes, contrato das funções e configuração em **[06-BANCO-DE-DADOS.md](06-BANCO-DE-DADOS.md)**; SQL em `supabase/migrations/`.

## 8. API Belasis — validada contra a documentação oficial

Mapeamento completo, limites e decisões em **[05-BELASIS-API.md](05-BELASIS-API.md)**. Resumo do que muda neste TRD:

- Todos os endpoints necessários existem (cliente, histórico via `schedule_groups`, serviços, profissionais, `free_times`, criar/cancelar agendamento). **Plano B não é necessário.**
- **Rate limit de 30 req/min** → todas as chamadas passam pelo sub-workflow `Belasis · Request` (limitador + cache + retry em 429).
- Busca de cliente é textual (`search`), não exata → match de telefone feito no n8n.
- `free_times` é por profissional e por dia e não considera a duração → busca dia a dia até 3 opções e checagem de slots consecutivos.
- Remarcar = criar novo + cancelar antigo.
- `available_to_online_scheduling` define quais serviços o bot pode agendar sozinho.
- Sem webhooks → revalidar horário antes de gravar.

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
