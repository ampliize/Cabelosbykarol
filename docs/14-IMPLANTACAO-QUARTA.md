# Implantação — quarta-feira, 9h

## Como está agora (teste aberto, 23/10)
- WhatsApp do agente: instância `cableos mvp teste 01`, número **11 92218-5643**. Qualquer número que escrever é atendido (`modo_piloto = false`). Equipe é ignorada, exceto quem está em `whitelist_piloto`.
- Avisos da equipe: só para o próprio 11 92218-5643 (`encaminhar_somente_para`).
- Agendamento pelo WhatsApp (27/10): o agente pergunta serviço, dia, **horário** e **profissional** (o banco recusa sem isso), confere a agenda real e agenda **CONFIRMADO** no Belasis (`belasis_status_agendamento`), para o Belasis mandar a confirmação. Cliente sem cadastro: pede nome completo + nascimento e cadastra. Trocar horário cancela o anterior; desmarcar cancela no Belasis (só agendamento da própria cliente). Depois de agendar, oferece 1 serviço complementar (venda casada pelo histórico real). Durante o teste vai para o profissional **Davy - Teste** (`belasis_escrita_profissional_teste = 172890`); a profissional pedida fica na observação.
- Painel: abas Atendimento · Agenda do salão (grade/lista com filtros) · Ranking · Indicadores. Atualiza sozinho a cada minuto; agenda do dia sincroniza com o Belasis a cada ~2 min.

## Virada para produção (na quarta, antes das 9h)
```sql
-- 1. agendamentos vão para a profissional pedida (ou quem mais faz o serviço e está livre)
update config_bot set valor = 'null' where chave = 'belasis_escrita_profissional_teste';
-- 2. avisos para a equipe real (Vitória → Emilly → Tauã)
update config_bot set valor = 'null' where chave = 'encaminhar_somente_para';
```
3. Conectar o **número oficial do salão** na Evolution (ou trocar `evolution_instancia`) e conferir o webhook `MESSAGES_UPSERT` + Base64.
4. Apagar no Belasis os agendamentos de teste (observação "TESTE de integração") e a cliente "Teste Ampliize".

## Base de dúvidas e objeções
30 itens novos (`fonte = 'ampliize'`) com orientação de resposta. Onde o salão ainda não informou (parcelamento, feriado, criança, preparo, desconto) o agente confirma com a equipe. Revisar com a Karol: `select pergunta, resposta from kb_itens where fonte = 'ampliize' order by id;`

## Botões de emergência
```sql
update config_bot set valor = 'false' where chave = 'belasis_escrita_automatica'; -- para de lançar/cancelar no Belasis (volta a só avisar a equipe)
update config_bot set valor = '"unconfirmed"' where chave = 'belasis_status_agendamento'; -- volta a entrar NÃO CONFIRMADO
update config_bot set valor = 'false' where chave = 'bot_ativo';                  -- agente para de responder
update config_bot set valor = '"desligado"' where chave = 'belasis_modo';        -- corta toda leitura/escrita no Belasis
```

## Garantias da escrita automática
- Só `POST /clients` e `POST /schedule_groups` (lista branca na Edge Function); nunca altera nem apaga.
- Sempre `status = unconfirmed`, com observação "Pré-agendamento pelo WhatsApp (assistente IA)".
- POST nunca é repetido sozinho (sem duplicidade). Falhou → aviso "lançar manualmente" com o motivo.
- Testado em 23/10: cliente existente (id 36153706) e cliente nova (cadastro + agendamento id 36153934), ambos 201.
