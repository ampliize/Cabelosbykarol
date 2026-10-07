-- Teste: mensagens automáticas do Belasis no mesmo WhatsApp.
-- Termina com RAISE EXCEPTION (desfaz tudo); esperado: "RESULTADO 7 de 7 ok".
do $$
declare res jsonb := '[]'; r jsonb; c uuid; n int; h jsonb;
begin
  update public.config_bot set valor = '["5511900000055","5511900000056"]' where chave = 'whitelist_piloto';
  r := public.registrar_mensagem_entrada('L-1','5511900000055',true,'text','Olá, Ju! Passando para lembrar do seu horário amanhã às 15h com a Ana. Responda SIM para confirmar 💛');
  c := (r->>'conversa_id')::uuid;
  res := res || jsonb_build_object('t','lembrete_nao_pausa','ok', r->>'motivo'='mensagem_automatica' and (select status from public.conversas where id=c)='bot');
  r := public.registrar_mensagem_entrada('L-2','5511900000055',false,'text','Sim, confirmo!',null,'Ju');
  res := res || jsonb_build_object('t','resposta_vai_pro_agente','ok', r->>'acao'='processar');
  h := public.contexto_conversa(c, 20);
  res := res || jsonb_build_object('t','historico_tem_lembrete','ok', jsonb_array_length(h)=2 and h->0->>'autor'='sistema');
  r := public.registrar_retorno_lembrete(c, 'confirmou', 'Progressiva amanhã 15h com Ana');
  select count(*) into n from public.notificacoes_equipe where conversa_id=c and tipo='retorno_lembrete' and resumo like 'Cliente CONFIRMOU%Progressiva%';
  res := res || jsonb_build_object('t','avisa_equipe_confirmacao','ok', (r->>'ok')::boolean and n=1 and (select status from public.conversas where id=c)='bot');
  r := public.registrar_retorno_lembrete(c, 'talvez');
  res := res || jsonb_build_object('t','resposta_invalida','ok', not (r->>'ok')::boolean);
  r := public.registrar_mensagem_entrada('L-3','5511900000056',true,'text','Oi amore, aqui é a Karol! Consegui um encaixe pra você sexta');
  res := res || jsonb_build_object('t','equipe_real_pausa','ok', r->>'motivo'='humano_respondeu');
  r := public.registrar_mensagem_entrada('L-4','5511900000056',true,'text','Feliz aniversário, Bia! 🎉 Ganhe 10% de cashback este mês');
  res := res || jsonb_build_object('t','aniversario_eh_automatica','ok', r->>'motivo'='mensagem_automatica');
  select count(*) filter (where (x->>'ok')::boolean) into n from jsonb_array_elements(res) x;
  raise exception 'RESULTADO % de % ok: %', n, jsonb_array_length(res),
    (select jsonb_agg(x->>'t') from jsonb_array_elements(res) x where not (x->>'ok')::boolean);
end $$;
