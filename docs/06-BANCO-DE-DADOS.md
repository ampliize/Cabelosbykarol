# Banco de dados (Supabase "cabelos by karol")

Migrations em [`supabase/migrations/`](../supabase/migrations) (já aplicadas no projeto). Teste de fluxos em [`supabase/tests/fluxos.sql`](../supabase/tests/fluxos.sql): usa dados fictícios e apaga tudo no final.

## Acesso

- **Só o n8n acessa**, com a credencial Postgres (ou `service_role`). RLS ligado em todas as tabelas, sem policies, e sem privilégio para `anon`/`authenticated`: a chave pública não lê nada.
- A lógica sensível (dedupe, pausa, anti-ban, idempotência) fica em **funções no banco**, para o n8n ficar simples e as regras ficarem num lugar só.

## Tabelas

| Tabela | Para quê |
|---|---|
| `config_bot` | Parâmetros e kill switch (ver abaixo) |
| `equipe` | Números da equipe (ignorados pelo bot) e quem recebe transferências |
| `conversas` | 1 por telefone: status (`bot` / `humano_assumiu` / `aguardando_humano`), pausa, opt-out, id da cliente no Belasis |
| `mensagens` | Todas as mensagens de entrada e saída; `processada_em` nulo = no buffer de agrupamento |
| `n8n_chat_histories` | Memória do AI Agent (nó *Postgres Chat Memory*, `session_id = conversas.id`) |
| `execucoes_agente` | Tokens, latência, tool calls e erros de cada resposta |
| `acoes_belasis` | Auditoria + idempotência de toda escrita no Belasis, com o "sim" literal da cliente |
| `handoffs` | Transferências para humano |
| `kb_itens` | Base de conhecimento (só `aprovado = true` vai para o bot); busca em português sem acento |
| `cache_belasis` | Cache das respostas do Belasis |
| `rate_limit` | Contador por minuto (Belasis 25/min, envio WhatsApp 20/min) |

Views: `vw_metricas_diarias`, `vw_handoffs_abertos`, `vw_alertas_escrita_sem_confirmacao` (deve ficar sempre vazia).

Rotina `cbk-limpeza-diaria` (pg_cron, 03:17 BRT): apaga mensagens/logs com mais de `retencao_mensagens_dias`, cache vencido e contadores antigos.

## Funções que o n8n chama

| Onde (workflow) | Função | Retorno |
|---|---|---|
| `WA · Entrada`, para todo webhook | `registrar_mensagem_entrada(message_id, telefone, from_me, tipo, texto, media_url, push_name, jid, raw)` | `acao`: `processar` / `humano` / `ignorar` + `motivo`, `conversa_id`, `mensagem_id`, `janela_segundos` |
| `WA · Entrada`, após esperar a janela | `coletar_lote(conversa_id, mensagem_id)` | `processar=true` com `texto` juntado e `imagens`, ou `processar=false` (outra execução cuida) |
| `WA · Enviar`, antes de cada bloco | `verificar_envio(conversa_id)` | `permitido` + `aguardar_ms` (intervalo por conversa) ou `motivo` do bloqueio |
| `WA · Enviar`, após enviar | `registrar_mensagem_saida(conversa_id, texto, message_id)` | id |
| `Belasis · Request`, antes de cada chamada | `reservar_chamada_belasis()` | `permitido` / `aguardar_ms` |
| `Belasis · Request`, ao receber 429 | `bloquear_cota('belasis')` | — |
| `Belasis · Request` | `cache_get(chave)` / `cache_set(chave, valor, ttl_segundos)` | jsonb / — |
| `Tool · agendar_horario` / `alterar_agendamento` | `reservar_acao_belasis(chave, conversa_id, acao, request, confirmacao)` → chamar API → `concluir_acao_belasis(...)` | `executar=false` se já foi feito (não duplica) |
| `Tool · transferir_para_humano` | `iniciar_handoff(conversa_id, motivo, resumo)` | `destinatarios` para notificar |
| `Tool · consultar_base_conhecimento` | `buscar_kb(consulta, categoria, limite)` | itens aprovados ordenados por relevância |

### Regras que o banco aplica sozinho

- **Dedupe**: mesmo `message_id` duas vezes → `ignorar/duplicada`.
- **Eco do bot**: mensagem `from_me` igual a uma que o bot enviou há menos de 2 min → ignorada.
- **Humano assumiu**: qualquer outra mensagem `from_me` pausa o bot por `pausa_humano_horas`. Exceção: textos que casam com `padroes_mensagens_automaticas` (lembretes da extensão Belasis) → autor `sistema`, sem pausa.
- **`/bot`** enviado pela equipe na conversa devolve a conversa ao bot (depois, apague a mensagem "para todos").
- **Pausa vencida** volta para o bot automaticamente na próxima mensagem da cliente.
- **Kill switch**, **modo piloto** (whitelist), **opt-out** e **janela de 24 h** para envio.
- Mensagens que o bot não vai tratar saem do buffer na hora e não entram num lote futuro.
- **Telefone**: tudo normalizado para `55 + DDD + número` (acrescenta o 9º dígito que falta); número estrangeiro é ignorado.

## Configuração (`config_bot`)

| Chave | Padrão | Ação necessária |
|---|---|---|
| `bot_ativo` | `true` | Kill switch |
| `modo_piloto` | `true` | **Mudar para `false` no go-live (08/10)** |
| `whitelist_piloto` | `[]` | Colocar os números da equipe e das clientes do piloto |
| `pausa_humano_horas` | `4` | Karol decide |
| `timeout_aguardando_humano_horas` | `12` | |
| `janela_agrupamento_segundos` | `8` | |
| `envio_intervalo_min_ms` / `envio_limite_por_minuto` | `3000` / `20` | Regras anti-ban |
| `belasis_limite_por_minuto` | `25` | Limite oficial é 30 |
| `dias_busca_horarios` / `max_opcoes_horario` | `14` / `3` | |
| `status_agendamento_bot` | `"confirmed"` | Karol decide |
| `padroes_mensagens_automaticas` | `[]` | **Preencher com o início dos lembretes que a extensão Belasis envia** |
| `horario_funcionamento` | tudo `null` | **Preencher** |
| `retencao_mensagens_dias` | `180` | |

Exemplos:

```sql
update config_bot set valor = '["5511999990001","5511999990002"]' where chave = 'whitelist_piloto';
update config_bot set valor = '{"ter":["09:00","19:00"],"qua":["09:00","19:00"],"qui":["09:00","19:00"],"sex":["09:00","19:00"],"sab":["08:00","17:00"],"seg":null,"dom":null}' where chave = 'horario_funcionamento';
insert into equipe (nome, telefone, papel, recebe_handoff) values ('Karol', '5511999990001', 'dona', true);
update config_bot set valor = 'false' where chave = 'bot_ativo';   -- desliga tudo na hora
```
