# Plano de Entrega — até 08/10/2026

## Cronograma

| Dia | Entregas | Critério de pronto |
|---|---|---|
| **Qua 30/09** | PRD, TRD, arquitetura (este repo). Enviar ao cliente a lista de pendências abaixo | Docs revisados pela Ampliize |
| **Qui 01/10** | ✅ Documentação da API Belasis analisada ([05-BELASIS-API.md](05-BELASIS-API.md)). Rodar `scripts/belasis-smoke.sh` com a chave real. Subir Supabase (schema TRD §7) e instância da API WhatsApp com **número de teste** | Planilha de endpoints ✅/❌; mensagem de teste chegando no n8n |
| **Sex 02/10** | `WA · Entrada`, `WA · Enviar`, buffer, dedupe, humano assumiu. Rodar pipeline de KB com o export do WhatsApp | Mensagem de teste ida e volta; KB rascunho gerada |
| **Sáb 03 – Dom 04/10** | Sub-workflows Belasis (cliente, serviços, horários, agendar, alterar). `Agente · Core` com prompt v1 | Caso "mesma profissional" funcionando ponta a ponta em homologação |
| **Seg 05/10** | Handoff, áudio/imagem, contingências, Error Workflow. Revisão da KB e tom de voz com a Karol | KB aprovada; todos os casos obrigatórios (TRD §9) rodando |
| **Ter 06/10** | Suíte de avaliação + ajustes de prompt. Teste com a equipe do salão (roleplay) | ≥ 90% da suíte passando; 0 escrita sem confirmação |
| **Qua 07/10** | Conectar número de produção. Piloto restrito (bot só responde números whitelist da equipe/clientes amigas) | Piloto sem incidentes |
| **Qui 08/10** | **Go-live** para todos. Monitoramento humano ativo, revisão diária de conversas por 7 dias | Bot atendendo em produção |

Plano B (**provavelmente desnecessário**: a API expõe `free_times` e criação de agendamento; manter só se o teste real falhar): go-live com F1, F2, F3 (identificação + FAQ + sugestão de repetir serviço), F7–F11, e agendamento feito por humano a partir do handoff com resumo pronto.

## Pendências com o cliente

- [x] Documentação da API Belasis
- [ ] Chave da API Belasis (`bpk_...`) — addon de API ativo na conta; de preferência uma chave exclusiva para o bot
- [ ] Confirmar como a extensão Belasis está conectada ao WhatsApp (WhatsApp Web? app Business?) e se o número é WhatsApp Business
- [ ] Export de 50–150 conversas do WhatsApp (últimos 3–6 meses, sem mídia)
- [ ] Políticas: cancelamento, atraso, sinal, formas de pagamento, endereço, estacionamento, horários
- [ ] Serviços que **sempre** exigem avaliação presencial/humano
- [ ] Números da equipe (ignorar / detectar humano assumindo)
- [ ] Para quem vai a transferência (número ou grupo) e horário de cobertura
- [ ] Volume médio de conversas/mês (para custo)
- [ ] Aprovação do texto de apresentação do bot

## Decisões em aberto

| # | Decisão | Recomendação | Dono |
|---|---|---|---|
| 1 | ~~Canal~~ | ✅ Decidido: API não oficial com regras anti-ban (TRD §2.1); número real só no piloto 07/10 | — |
| 2 | Bot agenda direto ou só pré-agenda para a recepção confirmar? | Agenda direto com confirmação da cliente | Karol |
| 3 | Horas de pausa quando humano assume | 4 h | Karol |
| 5 | Status do agendamento criado pelo bot: `confirmed` ou `unconfirmed`? | `confirmed` (cliente confirmou no chat) | Karol |
| 6 | Quais serviços o bot agenda sozinho? | Os marcados como "agendamento online" no Belasis | Karol |
| 4 | Bot atende fora do horário comercial? | Sim, agenda e avisa que humanos respondem no próximo expediente | Karol |
