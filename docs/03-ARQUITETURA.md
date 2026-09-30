# Arquitetura

## 1. Visão geral

```mermaid
flowchart LR
    C([Cliente no WhatsApp]) <--> WA[WhatsApp do salão]
    WA <-->|extensão atual| BX[Extensão Belasis]
    WA <-->|Cloud API coexistência<br/>ou Evolution API| AD

    subgraph N8N[n8n]
        AD[channel_adapter] --> IN[Entrada:<br/>filtros, dedupe,<br/>humano assumiu?]
        IN --> MID[Mídia:<br/>áudio→texto, imagem]
        MID --> BUF[Buffer 8s]
        BUF --> CTX[Carregar contexto<br/>cliente + histórico + memória]
        CTX --> AG{{AI Agent<br/>Claude}}
        AG --> T1[buscar_servicos]
        AG --> T2[consultar_horarios]
        AG --> T3[agendar_horario]
        AG --> T4[alterar_agendamento]
        AG --> T5[consultar_base_conhecimento]
        AG --> T6[transferir_para_humano]
        AG --> OUT[Formatar e enviar]
        OUT --> AD
    end

    CTX --> BAPI[(API Belasis)]
    T1 --> BAPI
    T2 --> BAPI
    T3 --> BAPI
    T4 --> BAPI
    BX --- BAPI

    IN --> SB[(Supabase)]
    CTX --> SB
    T5 --> SB
    T6 --> SB
    OUT --> SB
    T6 -->|notificação + resumo| EQ([Equipe do salão])
```

Princípios aplicados:

- **Um agente só, poucas ferramentas** (skills *project-development* / *tool-design*): o problema é um diálogo com 6 ações bem definidas — não há ganho em multi-agente, só latência e custo.
- **Determinístico em volta, LLM no meio**: filtros, buffer, contexto, guardas de escrita e envio são código; o LLM só conversa e escolhe ferramentas.
- **Belasis é a fonte da verdade** para dados vivos (agenda, preços, histórico). Supabase guarda estado da conversa, KB e logs — nunca uma cópia da agenda.
- **Canal isolado num adaptador**: trocar Cloud API ↔ Evolution API não mexe no agente.

## 2. Sequência — "quero progressiva com a mesma profissional"

```mermaid
sequenceDiagram
    autonumber
    actor Cli as Cliente
    participant WA as WhatsApp
    participant N as n8n
    participant SB as Supabase
    participant B as API Belasis
    participant AI as Claude (Agent)

    Cli->>WA: "Quero fazer progressiva de novo com a mesma moça"
    WA->>N: webhook
    N->>SB: dedupe + status da conversa + buffer
    N->>B: cliente por telefone + últimos atendimentos + próximos agendamentos
    B-->>N: Juliana · Progressiva c/ Ana em 12/07
    N->>AI: prompt + contexto + mensagem
    AI->>N: consultar_horarios(progressiva, Ana, hoje..+14d)
    N->>B: disponibilidade
    B-->>N: slots
    N-->>AI: 3 slots
    AI-->>N: "Oi Juliana! A Ana tem qui 14h, sex 9h, sáb 10h"
    N->>WA: envia
    Cli->>WA: "Sexta 9h"
    WA->>N: webhook
    N->>AI: contexto + memória
    AI-->>N: resumo + "Posso agendar?"
    N->>WA: envia
    Cli->>WA: "Pode"
    N->>AI: contexto + memória
    AI->>N: agendar_horario(..., confirmacao_cliente="Pode")
    N->>B: revalida slot → POST agendamento
    B-->>N: ok (id)
    N->>SB: acoes_belasis (auditoria)
    AI-->>N: "Prontinho, agendado!"
    N->>WA: envia
```

## 3. Estados da conversa

```mermaid
stateDiagram-v2
    [*] --> bot
    bot --> aguardando_humano: transferir_para_humano
    bot --> humano_assumiu: equipe respondeu pelo celular (from_me)
    aguardando_humano --> humano_assumiu: equipe respondeu
    humano_assumiu --> bot: pausado_ate expirou
    aguardando_humano --> bot: equipe devolve (comando /bot) ou timeout
```

## 4. Workflows n8n

| Workflow | Tipo | Responsabilidade |
|---|---|---|
| `WA · Entrada` | Webhook (shell) | Recebe do canal, normaliza, dedupe, detecta `from_me`, checa status, mídia, buffer; chama `Agente · Core` |
| `WA · Enviar mensagem` | Sub-workflow | Único ponto de envio: quebra em blocos, delay de digitação, loga |
| `Agente · Core` | Sub-workflow | Carrega contexto, AI Agent + memória + ferramentas, retorna resposta |
| `Tool · buscar_servicos` | Sub-workflow (tool) | Serviços/preços/profissionais (cache 1 h) |
| `Tool · consultar_horarios` | Sub-workflow (tool) | Disponibilidade Belasis |
| `Tool · agendar_horario` | Sub-workflow (tool) | Revalida + cria + audita + idempotência |
| `Tool · alterar_agendamento` | Sub-workflow (tool) | Remarca/cancela com checagem de dono |
| `Tool · consultar_base_conhecimento` | Sub-workflow (tool) | KB aprovada no Supabase |
| `Tool · transferir_para_humano` | Sub-workflow (tool) | Muda status, gera resumo, notifica equipe |
| `Belasis · Cliente por telefone` | Sub-workflow | Normaliza telefone, busca, cache |
| `KB · Pipeline histórico` | Manual | Acquire→prepare→process→parse→render do export do WhatsApp |
| `Ops · Erros` | Error Trigger | Alerta Ampliize em falhas |
| `Ops · Reativar bot` | Cron 15 min | Volta conversas `humano_assumiu` expiradas para `bot` |

## 5. Pipeline de conhecimento (execução única + reexecuções)

```mermaid
flowchart LR
    E[Export WhatsApp<br/>.txt] --> P1[Prepare<br/>parse + anonimiza]
    P1 --> P2[Process<br/>Haiku extrai FAQ,<br/>políticas, tom]
    P2 --> P3[Parse<br/>agrupa, deduplica,<br/>resolve conflitos]
    P3 --> R{Revisão<br/>Karol/Ampliize}
    R -->|aprovado| KB[(kb_itens)]
    R --> TV[tom-de-voz.md<br/>few-shot]
    R --> EV[casos de avaliação]
```

## 6. Ambientes

| Ambiente | Canal | Belasis | Uso |
|---|---|---|---|
| Homologação | Evolution API com número de teste | Credencial de homologação / unidade teste | Desenvolvimento e suíte de avaliação |
| Produção | Número do salão (Cloud API coexistência ou Evolution) | Produção | Go-live 08/10 com monitoramento |
