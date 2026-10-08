# Passo a passo para começar os testes

Tempo estimado: 40–60 min. Marque cada item. Onde diz **"me avise"**, eu faço a parte do banco/n8n.

## Etapa 0 — Decidir os números

| Papel | O que é | Exemplo |
|---|---|---|
| **Número do agente** | WhatsApp conectado na Evolution que vai *responder*. Para teste, use um **chip de teste**, não o número do salão. | chip novo / número da Ampliize |
| **Números de teste (clientes)** | Até 2 WhatsApps que vão *conversar* com o agente | seu celular, celular de outra pessoa |
| **Quem recebe os avisos no teste** | Para a Vitória, a Emilly e o Tauã não receberem avisos de teste | um dos seus números |

➡️ **Me avise:** os 2 números de teste + o número que recebe os avisos.

## Etapa 1 — Evolution API (número do agente)

1. Na Evolution, crie uma instância (ex.: `cbk-teste`) e conecte o **número do agente** pelo QR code.
2. Anote a **URL da Evolution** (ex.: `https://evo.seudominio.com`), o **nome da instância** e a **API key**.
3. ➡️ **Me avise** a URL e o nome da instância. A API key **não** precisa me mandar: ela vai só na credencial do n8n (Etapa 2).

## Etapa 2 — Credenciais no n8n (Credentials → Add credential)

| Nome (exatamente) | Tipo | Campos |
|---|---|---|
| `CBK Supabase Postgres` | Postgres | Supabase → **Connect** → *Session pooler*: Host `aws-…pooler.supabase.com`, Port `5432`, Database `postgres`, User `postgres.cuofrppbluatjniserio`, Password (senha do banco), **SSL: require** |
| `CBK Evolution API` | Header Auth | Name: `apikey` · Value: API key da Evolution |
| `CBK Webhook Secret` | Header Auth | Name: `x-cbk-secret` · Value: o segredo que te passei antes (o mesmo do Vault do Supabase) |
| `CBK Belasis API` | Header Auth | Name: `ACCESS-TOKEN` · Value: chave `bpk_...` do Belasis |
| `OpenAI account` | — | já existe |

## Etapa 3 — Trocar credenciais nos workflows

O n8n preencheu sozinho credenciais de **outro cliente** ("Postgres account" e "Header Auth account"). Em **cada** workflow `CBK · …`, abra os nós abaixo e selecione a credencial CBK correta:

| Workflow | Nós |
|---|---|
| CBK · WA Entrada | Registrar entrada, Salvar transcrição, Coletar lote → `CBK Supabase Postgres` |
| CBK · Agente Core | Carregar contexto, Registrar execução, Erro: encaminhar…, e as ferramentas consultar_base_conhecimento, transferir_para_humano, registrar_retorno_lembrete, registrar_pre_agendamento → `CBK Supabase Postgres` |
| CBK · WA Enviar | Verificar regras de envio, Registrar mensagem enviada → `CBK Supabase Postgres` · Enviar texto (Evolution) → `CBK Evolution API` |
| CBK · WA Retomada | Webhook → `CBK Webhook Secret` · Coletar mensagens pendentes → `CBK Supabase Postgres` |
| CBK · Equipe Notificar | Webhook → `CBK Webhook Secret` · Ler config, Marcar como enviada, Marcar erro → `CBK Supabase Postgres` · Enviar WhatsApp → `CBK Evolution API` |
| CBK · Erros | Encaminhar alerta → `CBK Supabase Postgres` |
| CBK · Belasis Request | Autorizar, Registrar chamada → `CBK Supabase Postgres` · Belasis GET/POST/PATCH → `CBK Belasis API` |
| CBK · Belasis Varredura | Webhook → `CBK Webhook Secret` · Salvar varredura → `CBK Supabase Postgres` |

➡️ **Me avise** quando terminar: eu confiro nó por nó que nenhum ficou com credencial errada.

## Etapa 4 — Ativar

1. Em cada workflow CBK: **Settings → Error Workflow = `CBK · Erros`**.
2. **Publicar/ativar**: `CBK · WA Entrada`, `CBK · WA Retomada`, `CBK · Equipe Notificar`, `CBK · Erros`. (Agente Core, WA Enviar e Belasis Request são chamados pelos outros.)

## Etapa 5 — Webhook da Evolution

Na instância → **Webhook**:
- URL: `https://n8n-n8n.dgwpoe.easypanel.host/webhook/cbk-wa-entrada-7f3k9q`
- Evento: **MESSAGES_UPSERT**
- **Webhook Base64: ligado** (para transcrever áudio)

## Etapa 6 — Eu configuro (depois dos seus avisos)

- `evolution_base_url` e `evolution_instancia`
- `whitelist_piloto` = os 2 números de teste (o agente **só responde** a eles)
- `encaminhar_somente_para` = número que recebe os avisos (modo teste)
- Belasis: modo `varredura` → rodo a varredura somente leitura → volto para `desligado` e te mando o relatório

## Etapa 7 — Roteiro de teste (cada número)

| # | Mande | Esperado |
|---|---|---|
| 1 | "oi, bom dia" | resposta curta e carinhosa, sem se apresentar como robô |
| 2 | "qual o endereço? tem estacionamento?" | endereço + "estacionamento na rua" |
| 3 | 3 mensagens seguidas rápidas | **uma** resposta só, juntando tudo |
| 4 | um **áudio** pedindo escova | entende o áudio |
| 5 | "quero fazer coloração" | explica o teste de mecha gratuito e oferece pré-agendar o teste |
| 6 | "escova sábado às 10h com a Paty" → "pode" | pré-agendamento; aviso "📅 Pré-agendamento" chega no número de avisos; agente **não** diz "confirmado" |
| 7 | "segunda às 10h" | avisa que segunda é fechado e pede outro dia |
| 8 | "quanto custa a progressiva?" | não inventa preço; encaminha |
| 9 | "fiquei insatisfeita com meu cabelo" | acolhe e encaminha (aviso 🔔) |
| 10 | **Do número do agente**, responda você mesmo a cliente | agente fica quieto; se você parar de responder por 3 min e a cliente escrever, ele volta |
| 11 | "você é um robô?" | responde com honestidade e leveza |

Depois de testar: me diga o que estranhou. Eu ajusto o tom/regras e você vê tudo no dashboard.
