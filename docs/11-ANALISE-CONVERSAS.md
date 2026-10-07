# Análise das conversas reais do salão

Fonte: 53 conversas exportadas do WhatsApp (03/07 a 07/10/2026, **10.177 mensagens**: 5.871 do salão e 4.306 de clientes) + prints de 4 mensagens automáticas do Belasis. Os dados brutos ficam fora do repositório; aqui só números e padrões.

## 1. O que as clientes pedem

| Assunto | Mensagens de cliente |
|---|---|
| **Agendar / disponibilidade** ("tem vaga hoje?", "amanhã às 9h?") | 648 |
| Confirmação ("sim", "confirmado") | 398 |
| Unhas (manicure, pé, gel, alongamento) | 218 |
| Cabelo técnico (selagem, coloração, luzes, bio adesivo) | 113 |
| Atraso / a caminho | 64 |
| Cancelar / remarcar | 41 |
| Preço | 16 |
| Produto, pagamento, endereço | < 10 cada |

**Conclusão:** a maior parte é agenda. Sem a API do Belasis, o agente faz o pré-agendamento e a equipe confirma o horário. A consulta de horários livres via API (última etapa) é o que mais vai tirar trabalho da recepção.

## 2. Tempo de resposta hoje (linha de base para o dashboard)

| | Mediana | 75% | 90% |
|---|---|---|---|
| Geral | 3,9 min | 31 min | 3,8 h |
| No expediente | 3,0 min | 19 min | 2,7 h |

- Só **50%** das mensagens no expediente são respondidas em até 3 min.
- **20%** das mensagens de clientes chegam fora do expediente (2% entre 20h e 6h).
- Pico: das 9h às 11h.

## 3. Jeito de escrever da equipe (aplicado no agente)

- Mensagens **curtíssimas** (mediana de 16 caracteres), várias seguidas.
- Tratamento: "meu bem" (277), "flor" (170), "amor/amore" (98), "minha linda" (32).
- Sempre "bom dia/boa tarde" + "tudo bem?" antes do assunto.
- Para agendar: "tem preferência de profissional?", "pode ser?" (338), "agendada", "infelizmente não temos…", "disponha".
- Emoji em só **4%** das mensagens (💖, 💕).

## 4. Mensagens automáticas do Belasis (reconhecidas pelo agente)

19 modelos encontrados (2.029 mensagens), entre eles: confirmação de agendamento ("…está OK. Beijosss"), lembrete da véspera ("aqui é do salão da Karol… Tá confirmado né?"), lembrete do dia, "é hoje!", "encontro marcado", agradecimento com avaliação, retorno após 30/45 dias ("só digitar SIM"), "como estão seus lindos cabelos?", "como vão as unhas divinas?", cancelamento ("Qual melhor dia e hora?"), alteração, pós-venda de produto, cuidados pós-alongamento, pesquisa de saudade, boas-vindas, avaliação no Google e reconquista.

- O Belasis troca espaços pelo caractere invisível **⠀ (U+2800)**; o banco normaliza antes de comparar.
- Nenhuma mensagem digitada pela equipe foi classificada como automática (validação nas 5.871 mensagens).
- Teste no banco: 11/11. Trava nova: o banco recusa regex inválido na lista de padrões.
- ⚠️ **Bug no Belasis do salão:** o modelo "amanhã temos um encontro marcado" sai com o texto literal **"%SERVIÇO%"** (65 vezes). Corrigir a variável no Belasis.

## 5. Equipe e serviços citados (RASCUNHO para o salão validar)

Profissionais nos agendamentos: **cabelo** Patrícia (Paty), Larissa (Lari), Thamires, Adley, Moisés, Thais, Karol; **unhas** Eli, Vitória, Jessica. Elaine se afastou (set/2026). "Aux" aparece junto do nome (ex.: "Lari Aux") — confirmar o significado.

Preços citados nas conversas (podem estar desatualizados; houve "ajuste de valor"):

| Serviço | Valor citado |
|---|---|
| Escova lisa/modelada | R$ 75 |
| Aplicação de hidratação (produto da cliente) / L'Oréal do salão | R$ 30 / R$ 145 |
| Manutenção alongamento capilar (Invisible Bio Adesivo) | R$ 370 |
| Selagem | R$ 300 |
| Luzes | R$ 690 |
| Matização | R$ 150 |
| Esmaltação em gel (mão) / 1 unha / remoção | R$ 90 / R$ 20 / R$ 25 |
| Pedicure (pé normal) | R$ 32 |
| Alongamento de unha (aplicação / manutenção) | R$ 180 / R$ 110 |
| Design com henna | R$ 65 |

Estão na base de conhecimento como **não aprovados**: o agente não usa até o salão confirmar. Hoje, se perguntarem preço, ele encaminha para a equipe.

## 6. O que mudou no agente

- Tom de voz real da equipe (seção 3).
- Respostas às mensagens automáticas: confirmou → avisa a equipe; atraso → tranquiliza (15 min) e avisa; não vai → oferece remarcar; "SIM" à mensagem de retorno ou resposta ao cancelamento → pré-agendamento do serviço citado; agradecimento/avaliação → agradece.
- Link de avaliação do Google na base de conhecimento.

## 7. Pendências para o cliente

- [ ] Validar a tabela de preços e a lista de profissionais (seção 5)
- [ ] O que significa "Aux" no nome das profissionais
- [ ] Corrigir o "%SERVIÇO%" no modelo "encontro marcado" do Belasis
- [ ] Texto da mensagem de aniversário (não veio nos prints)
