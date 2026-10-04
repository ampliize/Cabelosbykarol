# Workflows n8n

Instância: `https://n8n-n8n.dgwpoe.easypanel.host` · projeto pessoal **AMPLIIZE LTDA**.

| Workflow | ID | Gatilho | Função |
|---|---|---|---|
| CBK · WA Entrada | `HE587KeeR6jHPmhj` | Webhook `POST /webhook/cbk-wa-entrada-7f3k9q` (Evolution) | Normaliza a mensagem, `registrar_mensagem_entrada` (dedupe, eco, humano assumiu, piloto, equipe), transcreve áudio, espera a cliente terminar de digitar, `coletar_lote`, chama o Agente Core |
| CBK · Agente Core | `u92vb9ROLs93IBCY` | Execute Workflow | Contexto (`contexto_conversa`) → AI Agent (OpenAI) com ferramentas `consultar_base_conhecimento` e `transferir_para_humano` → log → WA Enviar. Falha do agente → handoff `erro_sistema` + mensagem de contingência |
| CBK · WA Enviar | `co5uOju877trWZ71` | Execute Workflow | Quebra em até 3 mensagens, `verificar_envio` (anti-ban), "digitando…", envia pela Evolution, `registrar_mensagem_saida` |
| CBK · WA Retomada | `VEdtBBXIy11602ms` | Webhook `POST /webhook/cbk-retomada-4m8x2p` (Supabase, header `x-cbk-secret`) | Equipe 3 min sem responder → `coletar_lote` das pendentes → Agente Core |
| CBK · Equipe Notificar | `f7yiW3F4zrqMyNQL` | Webhook `POST /webhook/cbk-notificar-9t2v6w` (Supabase, header `x-cbk-secret`) | Envia o encaminhamento no WhatsApp de cada destinatário da tabela `equipe` e chama `marcar_notificacao` |
| CBK · Erros | `gOntxmmecqInqf8c` | Error Trigger | Falha em qualquer workflow CBK → `encaminhar_para_responsavel('erro_sistema', …)` |

## Credenciais (criar no n8n)

| Nome | Tipo | Configuração | Usada em |
|---|---|---|---|
| CBK Supabase Postgres | Postgres | Supabase → Connect → Session pooler (host `aws-…pooler.supabase.com`, porta 5432, usuário `postgres.cuofrppbluatjniserio`, SSL on) | Todos os nós Postgres |
| CBK Evolution API | Header Auth | Name `apikey`, Value = API key da instância | WA Enviar, Equipe Notificar |
| CBK Webhook Secret | Header Auth | Name `x-cbk-secret`, Value = segredo `n8n_webhook_retomada_secret` do Vault do Supabase | Webhooks Retomada e Notificar |
| OpenAI account | OpenAI | já existente | Agente Core, transcrição |

> Na criação, o n8n atribuiu automaticamente as credenciais genéricas "Postgres account" e "Header Auth account" (de outro projeto). **Trocar todas** pelas CBK acima antes de ativar.

## Ativação

1. Trocar credenciais em todos os nós (Postgres, Header Auth, HTTP Request da Evolution).
2. Em cada workflow CBK → Settings → **Error Workflow = CBK · Erros**.
3. Publicar/ativar: WA Entrada, WA Retomada, Equipe Notificar, Erros (Agente Core e WA Enviar são sub-workflows).
4. Supabase: `update config_bot set valor = to_jsonb('https://evo…'::text) where chave = 'evolution_base_url'` e o mesmo para `evolution_instancia`.
5. Evolution → instância → Webhook: URL `https://n8n-n8n.dgwpoe.easypanel.host/webhook/cbk-wa-entrada-7f3k9q`, evento `MESSAGES_UPSERT`, **Webhook Base64 ligado**.
6. Piloto: adicionar números de teste em `whitelist_piloto` (números da tabela `equipe` são ignorados e não servem para testar o bot).
