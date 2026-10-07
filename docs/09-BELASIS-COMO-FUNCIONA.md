# Como o Belasis funciona: pesquisa pública e impacto no nosso agente

Pesquisa feita em 07/10/2026 em fontes públicas (site e blog do Belasis, Chrome Web Store, App Store, Reclame Aqui) **sem conectar a API**. A conexão com a API Belasis fica para a **última etapa** do projeto.

> Decisão do cliente: o **módulo de IA do Belasis não será ativado**. Todo atendimento no WhatsApp é do nosso agente de IA humanizado.

## 1. O que é o Belasis

Sistema 100% online de gestão para salões, barbearias, clínicas de estética e esmalterias (mais de 27 mil estabelecimentos, presente em 8 países). Módulos relevantes para nós:

| Módulo | O que faz | Relevância para o agente |
|---|---|---|
| **Agenda** | Agenda por profissional, tempo definido por serviço, intervalos entre serviços, bloqueio de horário (folga/manutenção), agendamento recorrente, lista de espera/encaixe | A agenda é a fonte da verdade. Hoje o agente **não lê**: coleta a preferência e a equipe marca |
| **Agendamento online** | Link/QR code (também via Instagram, Google, Facebook, site e app). A cliente escolhe serviço, profissional e horário, 24/7; pode remarcar/cancelar | **Caminho sem API:** o agente pode enviar o link para a cliente escolher sozinha (`link_agendamento_online`) |
| **Lembretes e confirmação** | Mensagens automáticas por WhatsApp/SMS para lembrar e pedir confirmação; a equipe também pode disparar "Enviar WhatsApp → Lembrete" manualmente | Saem do **mesmo número**: ver §2 |
| **Belasis Booster** (extensão Chrome) | Agenda e CRM dentro do WhatsApp Web: ver/criar agendamentos e pacotes da cliente na conversa | A equipe pode continuar usando: as mensagens que ela digita contam como "equipe assumiu" |
| **Marketing** | Campanhas por WhatsApp/SMS, aniversário com cupom, cashback, recuperação de clientes inativos | Mensagens automáticas do mesmo número; a cliente pode responder ao agente |
| **Pacotes e assinaturas** | Venda e controle de saldo de pacotes | Pergunta de saldo de pacote → encaminhar à equipe (agente não vê) |
| **Financeiro / comanda / conta digital** | Comanda, comissões, cobrança de **sinal** e pagamento online | Agente só informa a política (base de conhecimento), nunca cobra |
| **IA do Belasis** | Automação de confirmações, campanhas e relacionamento | **Não será ativada** (decisão do cliente) |

Status de agendamento (documentação da API): `confirmed` · `unconfirmed` · `disconfirm` (cancelado/faltou/remarcado) · `waiting` (cliente chegou).

## 2. O ponto mais importante: o Belasis e o agente usam o mesmo WhatsApp

Pelo que é público, o WhatsApp do Belasis funciona **pelo WhatsApp Web do salão** (extensão no Chrome, com computador ligado; há reclamações públicas justamente sobre isso). Então lembretes, confirmações, aniversários e campanhas **saem do número do salão**, e a Evolution vê essas mensagens como se a equipe tivesse escrito.

| Situação | Sem tratamento | Como resolvemos (já no banco e no agente) |
|---|---|---|
| Belasis manda lembrete "Passando para lembrar do seu horário amanhã…" | O agente acharia que a equipe assumiu e ficaria 3 min pausado | Mensagem reconhecida como **automática do salão** (`padroes_mensagens_automaticas`), não pausa o agente |
| Cliente responde "Sim, confirmo!" | Agente sem contexto, resposta estranha | O lembrete entra no histórico do agente como "Mensagem automática do salão". O agente agradece e chama `registrar_retorno_lembrete`, e a equipe recebe "✅ Cliente CONFIRMOU → marcar confirmado no Belasis" |
| Cliente responde "Não vou conseguir" | — | Agente acolhe, avisa a equipe para liberar o horário e oferece remarcar |
| Alguém da equipe escreve de verdade | — | Continua pausando o agente (regra dos 3 min) |
| Campanha em massa do Belasis pelo mesmo número | Aumenta o risco de bloqueio do número (API não oficial) | Combinar com o salão: **sem disparos em massa** pelo número do agente, ou campanhas pequenas e espaçadas |

Testado em `supabase/tests/convivencia_belasis.sql` (7/7).

> ⚠️ Os padrões de texto são genéricos. **Precisamos dos textos reais** dos lembretes/campanhas configurados no Belasis do salão para ajustar (`config_bot.padroes_mensagens_automaticas`).

## 3. Aparelhos conectados ao WhatsApp

O WhatsApp permite até 4 aparelhos vinculados. No número do salão ficarão: WhatsApp Web com o Belasis Booster (equipe) + Evolution (agente) + eventualmente o celular da recepção. Cabe, mas confirmar quantos já estão em uso.

## 4. O que muda no plano

1. **Agora (sem Belasis):** agente humanizado + base de conhecimento + encaminhamento + retorno em 3 min + entendimento dos lembretes do Belasis + link de agendamento online + dashboard.
2. **Piloto:** número real com whitelist; validar convivência com Booster e lembretes.
3. **Última etapa: API Belasis.** Infra já pronta e travada (`docs/08`): varredura somente leitura → modo leitura (agente sugere horários, equipe lança) → modo escrita (com aprovação).

## 5. Perguntas para o cliente (para fazer tudo certo sem conectar)

1. Qual o **link de agendamento online** do salão? Está ativo? Quais serviços aparecem nele?
2. Os **lembretes automáticos** estão ligados? Quanto tempo antes? Pode mandar o **texto exato** de cada mensagem automática (lembrete, confirmação, aniversário, cashback, campanhas)?
3. A equipe usa o **Belasis Booster** no WhatsApp Web? Em quantos computadores? O computador fica ligado o dia todo?
4. Quantos **aparelhos** já estão conectados ao WhatsApp do salão?
5. O salão faz **campanhas em massa** pelo WhatsApp? Com que frequência?
6. Cobra **sinal**? Qual a política de cancelamento/atraso/falta?
7. Trabalha com **pacotes**? A cliente costuma perguntar saldo pelo WhatsApp?
8. Quando a cliente confirma o lembrete hoje, **quem marca como confirmado** no Belasis?
9. Usa **lista de espera / encaixe**? Como funciona hoje?

## Fontes

- [Belasis — Recursos](https://www.belasis.com.br/en/recursos)
- [Como funciona o agendamento online Belasis](https://www.belasis.com.br/en/como-funciona-o-agendamento-online-belasis)
- [Agendamento online: como organizar horários no seu salão](https://www.belasis.com.br/agendamento-online-organizar-horarios-salao/)
- [Belasis — Inteligência artificial](https://www.belasis.com.br/recursos/intelig%C3%AAncia-artificial) · [Belasis IA](https://ia.belasis.com.br/)
- [Belasis — Campanhas de marketing](https://www.belasis.com.br/en/recursos/campanhas-de-marketing)
- [Como evitar faltas de clientes em horários-chave](https://www.belasis.com.br/como-evitar-faltas-clientes-horarios-chave-7-praticas/)
- [Lembretes de agendamento para esmalteria](https://www.belasis.com.br/lembretes-de-agendamento-para-esmalteria/)
- [Guia prático para cobrança de sinal](https://www.belasis.com.br/guia-pratico-para-cobranca-de-sinal)
- [Belasis Booster: Agenda e CRM no WhatsApp (Chrome Web Store)](https://chromewebstore.google.com/detail/belasis-booster-agenda-e/jfdmjhlfnfkohmglkagecammcjkcbnoi?hl=pt-BR) · [chrome-stats](https://chrome-stats.com/d/jfdmjhlfnfkohmglkagecammcjkcbnoi?hl=en)
- [Belasis Pro (App Store)](https://apps.apple.com/br/app/belasis-pro/id1310449315)
- [Belasis no Reclame Aqui](https://www.reclameaqui.com.br/empresa/belasis/lista-reclamacoes/) · [reclamação sobre WhatsApp/computador](https://www.reclameaqui.com.br/belasis/sistema-de-salao-de-beleza_njnCJTK_4T8sI4LI/)
