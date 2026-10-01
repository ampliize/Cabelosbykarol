# PRD — Agente de IA de Atendimento no WhatsApp (Cabelos by Karol × Belasis)

| Campo | Valor |
|---|---|
| Cliente | Cabelos by Karol (salão) |
| Responsável | Ampliize |
| Versão | 0.1 (rascunho para validação) |
| Data | 30/09/2026 |
| Go-live alvo | **08/10/2026** |

---

## 1. Problema

O atendimento do salão no WhatsApp é 100% manual. A equipe responde as mesmas perguntas várias vezes por dia (preço, horários, disponibilidade, "quero com a mesma profissional da última vez"), e parte das mensagens fica sem resposta fora do horário ou em horários de pico. Toda a informação necessária para responder **já existe** em dois lugares:

1. **Belasis** (sistema de gestão): clientes, histórico de serviços, profissionais, agenda, serviços e preços.
2. **Histórico do WhatsApp do salão**: como a equipe responde, dúvidas frequentes, políticas (sinal, atraso, cancelamento), tom de voz.

Hoje nenhuma dessas fontes é usada de forma automática.

## 2. Objetivo

Colocar no ar um agente de IA no WhatsApp do salão que **responde dúvidas e agenda/remarca serviços consultando o Belasis em tempo real**, com o tom de voz do salão e passagem para humano quando necessário.

### Exemplo guia (caso principal)

> **Cliente:** Oi! Quero fazer progressiva de novo, com a mesma moça da última vez.
>
> **Agente** *(identifica a cliente pelo telefone no Belasis → último serviço "Progressiva" em 12/07 com a profissional Ana → consulta agenda da Ana para progressiva)*
>
> **Agente:** Oi, Juliana! 💛 Sua última progressiva foi com a Ana, em julho. Ela tem estes horários livres: qui 03/10 às 14h, sex 04/10 às 9h ou sáb 05/10 às 10h. Qual fica melhor?
>
> **Cliente:** Sexta 9h
>
> **Agente:** Confirmando: **Progressiva com Ana — sex 04/10 às 9h**, valor a partir de R$ X. Posso agendar?
>
> **Cliente:** Pode
>
> **Agente** *(cria agendamento no Belasis)* Prontinho, agendado! Te mando lembrete um dia antes. ✨

## 3. Métricas de sucesso

| Métrica | Meta 30 dias após go-live |
|---|---|
| % conversas resolvidas sem humano | ≥ 60% |
| Tempo da 1ª resposta | < 30 s (24/7) |
| Agendamentos criados pelo agente | ≥ 30% do total de agendamentos via WhatsApp |
| Erros de agendamento (horário/profissional/serviço errado) | 0 tolerado — toda criação passa por confirmação explícita da cliente |
| Transferências para humano com contexto completo | 100% |
| Satisfação (amostragem manual semanal de conversas) | ≥ 4/5 |

## 4. Usuários

| Persona | Necessidade |
|---|---|
| **Cliente final** (recorrente) | Reagendar rápido, com a mesma profissional, sem esperar |
| **Cliente final** (nova) | Saber preços, serviços, localização, como funciona |
| **Recepção/equipe do salão** | Parar de responder o repetitivo; assumir a conversa quando precisar, sem o bot atrapalhar |
| **Karol (dona)** | Mais agendamentos, menos buraco na agenda, visão do que o bot está fazendo |
| **Ampliize (operação)** | Monitorar, ajustar base de conhecimento e prompts sem retrabalho |

## 5. Escopo

### 5.1 MVP — entrega 08/10 (P0)

| # | Funcionalidade | Descrição |
|---|---|---|
| F1 | **Identificação automática da cliente** | Pelo telefone do WhatsApp busca a cliente no Belasis e carrega nome, últimos serviços e profissionais. Sem cadastro → trata como cliente nova. |
| F2 | **Respostas de dúvidas (FAQ)** | Serviços, preços (faixa/"a partir de"), duração, endereço, horário de funcionamento, formas de pagamento, políticas. Fonte: base de conhecimento gerada do histórico do WhatsApp + Belasis. |
| F3 | **"Repetir com a mesma profissional"** | Detecta a intenção, usa o histórico do Belasis para descobrir serviço + profissional e sugere horários. |
| F4 | **Consulta de disponibilidade** | Busca horários livres por serviço, profissional (opcional) e período no Belasis. Oferece no máx. 3 opções. |
| F5 | **Agendamento com confirmação** | Cria o agendamento no Belasis **somente após "sim" explícito** da cliente a um resumo (serviço, profissional, data, hora). |
| F6 | **Remarcar e cancelar** | Localiza agendamento futuro da cliente e altera/cancela, também com confirmação. Respeita política de antecedência. |
| F7 | **Encaminhamento ao responsável** | Quando o agente não sabe responder, a cliente pede humano, há reclamação, problema no atendimento ou erro de sistema, a mensagem da cliente + resumo vão para o WhatsApp do responsável. Erros de sistema também alertam a Ampliize. |
| F8 | **Humano assume com retorno em 3 min** | Se alguém da equipe responder pelo WhatsApp, o agente pausa. Se ninguém da equipe falar por 3 minutos (o tempo reinicia a cada mensagem dela), o agente volta e responde o que ficou pendente. Transferência sem resposta em 3 min: o agente volta e o responsável recebe alerta. Só "não quero robô" não volta sozinho. |
| F9 | **Áudio e imagem** | Transcreve áudios recebidos; entende imagens (ex.: foto de referência de cabelo) e encaminha a humano quando for pedido de orçamento visual. |
| F10 | **Agrupamento de mensagens** | Espera a cliente terminar de digitar (janela ~8 s) antes de responder, para não responder frase por frase. |
| F11 | **Dashboard** | Painel web com conversas, % resolvido pelo agente, agendamentos, transferências, % respondidas pela equipe em 3 min, encaminhamentos (entregues ou não), quem está com a equipe agora, motivos, horários de pico, erros e uso de IA. |

### 5.2 Fase 2 (pós-go-live, P1)

- Lembrete de agendamento D-1 com confirmação ("responda 1 para confirmar").
- Reativação: cliente que fez progressiva há ~90 dias recebe sugestão de retorno (respeitando opt-in).
- Pedido de avaliação pós-atendimento.
- Painel web (Lovable) com conversas, métricas e editor da base de conhecimento.
- Lista de espera quando não há horário.

### 5.3 Fora de escopo

- Cobrança/pagamento pelo WhatsApp (sinal via Pix) — avaliar na fase 3.
- Orçamento de serviços que dependem de avaliação presencial (química/cor complexa) → sempre humano.
- Disparos em massa/marketing.

## 6. Regras de negócio

1. **Nunca inventar** preço, horário ou profissional. Só informar o que veio do Belasis ou da base de conhecimento aprovada.
2. **Nunca criar/alterar/cancelar** agendamento sem confirmação explícita da cliente ao resumo final.
3. Preços de serviços com variação (comprimento/volume) são informados como "a partir de" + convite para avaliação.
4. Se a profissional preferida não tiver horário em até **N dias** (padrão 14), oferecer: outra data mais distante, outra profissional do mesmo serviço, ou lista de espera/humano.
5. Cancelamento/remarcação com menos de **X horas** de antecedência (política do salão) → segue política e/ou transfere para humano.
6. Fora do horário de funcionamento o bot continua atendendo e agendando; transferências ficam em fila para o próximo expediente e a cliente é avisada.
7. Mensagens de grupos, status e números da equipe são ignorados.
8. Reclamação, insatisfação, reação alérgica/problema com procedimento → transferência imediata para humano, sem tentar resolver.

## 7. Tom de voz

Extraído do histórico real do WhatsApp do salão (ver TRD §4). Diretrizes iniciais: próximo, carinhoso, frases curtas, emojis com moderação (os que a equipe já usa), trata pelo primeiro nome, nunca soa como robô de URA. O agente se apresenta como assistente virtual do salão quando perguntado — não finge ser uma pessoa.

## 8. Requisitos não funcionais

| Requisito | Meta |
|---|---|
| Latência de resposta | p95 < 20 s após fim da janela de agrupamento |
| Disponibilidade | 24/7; se Belasis ou LLM falharem, mensagem de contingência + transferência para humano |
| Privacidade (LGPD) | Dados mínimos no prompt; histórico usado para a base de conhecimento é anonimizado; logs com retenção definida (padrão 180 dias) |
| Segurança | Chaves da API Belasis e WhatsApp só no servidor (n8n/Supabase secrets), nunca no prompt |
| Auditoria | Toda escrita no Belasis logada com id da conversa e mensagem de confirmação da cliente |

## 9. Dependências e premissas

| # | Item | Status |
|---|---|---|
| D1 | Documentação e credenciais da **API Belasis** (endpoints de cliente, histórico, profissionais, serviços, disponibilidade, agendamento) | ✅ temos a API — **enviar docs/credenciais de homologação** |
| D2 | Canal WhatsApp | ✅ API não oficial como aparelho vinculado (convive com a extensão Belasis) — conectar ao número real só no piloto |
| D3 | **Exportação do histórico do WhatsApp** do salão (conversas de 3–6 meses) | ⏳ pedir ao cliente |
| D4 | Políticas do salão (cancelamento, atraso, sinal, formas de pagamento, endereço, horários) | ⏳ pedir ao cliente |
| D5 | Lista de números da equipe (para ignorar/detectar "humano assumiu") | ⏳ pedir ao cliente |
| D6 | Quem recebe as transferências (número/grupo) | ⏳ pedir ao cliente |

## 10. Riscos

| Risco | Impacto | Mitigação |
|---|---|---|
| API Belasis não expõe disponibilidade/agendamento | Bloqueia F4–F6 | Validar endpoints no dia 01/10. Plano B: bot coleta preferência e transfere para humano agendar (MVP ainda entrega F1–F3, F7) |
| Conflito entre o bot e a extensão Belasis no mesmo número | Mensagens duplicadas / sessão derrubada | Teste de convivência no piloto (07/10) antes de liberar para todos |
| Banimento do número (API não oficial — decisão tomada) | Salão sem WhatsApp | Regras anti-ban do TRD §2.1: só responder, sem massa, delays humanos, limite de vazão, kill switch |
| Alucinação de preço/horário | Perda de confiança | Regras §6 no prompt + dados só via ferramentas + confirmação obrigatória + suíte de avaliação |
| Prazo curto (6 dias úteis) | Entrega parcial | Escopo P0 enxuto, fase 2 separada, go-live com monitoramento humano nos 3 primeiros dias |
