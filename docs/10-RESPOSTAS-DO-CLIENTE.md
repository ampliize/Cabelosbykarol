# Respostas do cliente: o que foi configurado

Fonte: "Checklist técnico — Configuração do Assistente de WhatsApp" (07/10/2026). Tudo abaixo já está no banco (`20261007150000_respostas_do_cliente.sql`, `20261007160000_pre_agendamento_validacao.sql`) e no **CBK · Agente Core**. Testes: `supabase/tests/respostas_cliente.sql` (15/15).

## Salão

| Item | Valor | Onde |
|---|---|---|
| Horário | Terça a sábado, 9h–18h (domingo e segunda fechado) | `horario_funcionamento`, base de conhecimento |
| Endereço | Rua Fenelon Santos, 132, Salgado Filho, Aracaju/SE (rua da Sorveteria Tchê, perto do canal) | base de conhecimento |
| Estacionamento | Não tem próprio; na rua | base de conhecimento |
| Pagamento | PIX, dinheiro e cartão | base de conhecimento |
| Sinal | Não cobra | base de conhecimento |
| Cancelamento/remarcação | Quando quiser, sem antecedência mínima | base de conhecimento |
| Atraso | Tolerância 15 min; cancelado após 20 min sem resposta | base de conhecimento |
| Avaliação/teste gratuitos | Alongamento → avaliação capilar · Luzes, selagem, coloração → teste de mecha | base de conhecimento + regra 4 do agente |

## Agendamento (como o cliente pediu)

1. O agente faz **pré-agendamento** (só terça a sábado, 9h–18h, e nunca no passado: o banco recusa e o agente pede outro horário).
2. Para alongamento/luzes/selagem/coloração, ele pré-agenda **primeiro a avaliação ou o teste gratuito**.
3. A equipe recebe "📅 Pré-agendamento — conferir a agenda, lançar no Belasis como **NÃO CONFIRMADO** e confirmar com a cliente".
4. O agente **nunca diz que o horário está confirmado**; só a equipe confirma.
5. Quando a API Belasis for ligada (última etapa), o agente cria direto como `unconfirmed` (`belasis_status_agendamento`) e a equipe valida.

## Encaminhamentos (ordem de preferência)

| Situação | Vai para |
|---|---|
| Transferência, dúvida, pré-agendamento, resposta a lembrete, **no expediente** | Vitória (recepção) |
| O mesmo **fora do expediente** (noite, domingo, segunda) | Emilly (24h) |
| Ninguém respondeu em 3 min (escala um nível) | Emilly; se já era a Emilly, Tauã |
| Erro de sistema | Tauã + Ampliize |

| Pessoa | Número | Prioridade | Disponível |
|---|---|---|---|
| Vitória (recepção) | 55 79 99813-4284 ⚠️ | 1 | expediente (horário dela não definido; usamos o do salão) |
| Emilly (coordenadora) | 55 79 99921-6161 | 2 | 24h |
| Tauã | 55 79 98125-6494 | 3 | 24h + alertas de sistema |

## Regra das 20h às 06h

- O agente **nunca inicia** conversa nesse intervalo, em qualquer dia (`pode_iniciar_conversa()`, config `silencio_proativo`).
- Se a cliente escrever, ele responde normalmente.
- Hoje o agente só responde (nunca puxa conversa); a função já está pronta para os envios proativos futuros (lembretes, reativação, pós-serviço, avaliação no Google).

## Piloto

Testadores: **Karol (55 79 99888-2219 ⚠️), Tauã e Emilly**. Como Tauã e Emilly também recebem encaminhamentos, durante o piloto **número da equipe que está na lista de teste é atendido como cliente**. Os avisos enviados a eles ("🔔 *…*") não contam como "equipe assumiu".

## ⚠️ Pontos de atenção

1. **5 aparelhos já conectados ao WhatsApp.** O WhatsApp aceita o celular principal + **4 aparelhos vinculados**. A Evolution (o agente) precisa de uma vaga → **desconectar um aparelho** antes de ligar.
2. **Números com dígito faltando:** Vitória veio como "79 9813-4284" e Karol como "79 9888-2219" (8 dígitos). Normalizamos para **99813-4284** e **99888-2219**. Confirmar. A Emilly aparece de dois jeitos no documento; usamos 99921-6161.
3. **E-mail do painel:** veio "tauãximenes1234@gmail.com" (com ã). E-mail não aceita acento; mantivemos **tauaximenes1234@gmail.com**.
4. **Preços:** o documento não traz tabela de preços. Até a API Belasis, o agente não informa valores (encaminha). Se quiserem, enviem uma tabela e ela entra na base de conhecimento.
5. A extensão Belasis fica no notebook do escritório: se ele desligar, os lembretes do Belasis param, mas o agente segue funcionando (é independente).

## Pendências do cliente

- [ ] Exportação das conversas do WhatsApp (3–6 meses, sem mídia) → tom de voz e perguntas frequentes
- [ ] Textos exatos das mensagens automáticas (parabéns, reativação, lembrete, cuidados pós-serviço, retorno de rotina, confirmação/cancelamento, boas-vindas, avaliação no Google)
- [ ] Volume médio mensal de conversas
- [ ] Horário da Vitória para receber encaminhamentos
- [ ] Liberar 1 vaga de aparelho conectado no WhatsApp
- [ ] (Opcional) Tabela de preços e link de agendamento online do Belasis
