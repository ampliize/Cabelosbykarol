-- Teste da devolução automática ao agente. Roda tudo dentro de um DO e termina
-- com RAISE EXCEPTION: a transação é desfeita (nada fica gravado) e o resultado
-- aparece na mensagem de erro, ex.: "RESULTADO 15 de 15 ok: <NULL>".
do $$
declare
  res  jsonb := '[]'::jsonb;
  r    jsonb;
  conv uuid;
  conv2 uuid;
  ult  bigint;
begin
  update public.config_bot set valor = '["5511900000001","5511900000002"]' where chave = 'whitelist_piloto';

  -- A. cliente fala, bot responde
  r := public.registrar_mensagem_entrada('R-1','5511900000001',false,'text','Oi, quero agendar progressiva',null,'Ju');
  conv := (r->>'conversa_id')::uuid;
  perform public.coletar_lote(conv, (r->>'mensagem_id')::bigint);
  perform public.registrar_mensagem_saida(conv, 'Oi Ju! Temos sexta 9h.');

  -- B. equipe assume -> timer de 3 min
  r := public.registrar_mensagem_entrada('R-2','5511900000001',true,'text','Ju, aqui e a Karol, deixa comigo');
  res := res || jsonb_build_object('teste','humano_assume','ok', r->>'motivo' = 'humano_respondeu');
  select jsonb_build_object('teste','timer_3min','ok', status = 'humano_assumiu' and round(extract(epoch from pausado_ate - now())/60) = 3)
    into r from public.conversas where id = conv;
  res := res || r;

  -- C. cliente escreve durante a pausa -> bot quieto
  r := public.registrar_mensagem_entrada('R-3','5511900000001',false,'text','Pode ser sexta 9h entao?');
  res := res || jsonb_build_object('teste','bot_quieto_na_pausa','ok', r->>'acao' = 'humano');

  -- D. equipe some -> job do cron devolve e reabre a pendente
  update public.conversas set pausado_ate = now() - interval '1 minute' where id = conv;
  r := public.devolver_conversas_ao_bot();
  res := res || jsonb_build_object('teste','cron_devolve','ok', (r->>'devolvidas')::int = 1);
  select jsonb_build_object('teste','status_bot','ok', status = 'bot' and pausado_ate is null) into r from public.conversas where id = conv;
  res := res || r;
  select ultima_mensagem_id, jsonb_build_object('teste','log_retomada','ok', origem = 'humano_inativo' and mensagens_pendentes = 1)
    into ult, r from public.retomadas_bot where conversa_id = conv order by id desc limit 1;
  res := res || r;
  r := public.coletar_lote(conv, ult);
  res := res || jsonb_build_object('teste','agente_recebe_pendente','ok', (r->>'processar')::boolean and r->>'texto' = 'Pode ser sexta 9h entao?');
  r := public.contexto_conversa(conv, 10);
  res := res || jsonb_build_object('teste','contexto_inclui_equipe','ok', jsonb_array_length(r) = 4 and r->2->>'autor' = 'humano');

  -- E. tolerância: timer quase vencendo + cliente escreve -> equipe ganha 3 min
  perform public.registrar_mensagem_entrada('R-4','5511900000001',true,'text','Ju, confirmei aqui');
  update public.conversas set pausado_ate = now() + interval '1 minute' where id = conv;
  perform public.registrar_mensagem_entrada('R-5','5511900000001',false,'text','Obrigada!');
  select jsonb_build_object('teste','tolerancia_3min','ok', round(extract(epoch from pausado_ate - now())/60) = 3)
    into r from public.conversas where id = conv;
  res := res || r;

  -- F. retomada imediata quando a cliente escreve antes do cron
  update public.conversas set pausado_ate = now() - interval '10 seconds' where id = conv;
  r := public.registrar_mensagem_entrada('R-6','5511900000001',false,'text','Oi? alguem ai?');
  res := res || jsonb_build_object('teste','retomada_lazy','ok', r->>'acao' = 'processar' and r->>'origem' = 'retomada');
  r := public.coletar_lote(conv, (r->>'mensagem_id')::bigint);
  res := res || jsonb_build_object('teste','lazy_inclui_pendente','ok', r->>'texto' = E'Obrigada!\nOi? alguem ai?');

  -- G. handoff: dúvida volta em 3 min; opt-out não volta sozinho
  r := public.registrar_mensagem_entrada('R-7','5511900000002',false,'text','oi',null,'Ana');
  conv2 := (r->>'conversa_id')::uuid;
  r := public.iniciar_handoff(conv2, 'fora_escopo', 'pergunta sobre produto');
  res := res || jsonb_build_object('teste','handoff_volta_3min','ok', (r->>'retorno_automatico')::boolean
          and round(extract(epoch from (r->>'bot_volta_em')::timestamptz - now())/60) = 3);
  r := public.iniciar_handoff(conv, 'opt_out', 'nao quer robo');
  res := res || jsonb_build_object('teste','opt_out_nao_volta','ok', not (r->>'retorno_automatico')::boolean and r->>'bot_volta_em' is null);
  update public.conversas set pausado_ate = now() - interval '1 minute' where id = conv2;
  r := public.devolver_conversas_ao_bot();
  res := res || jsonb_build_object('teste','cron_so_devolve_duvida','ok', (r->>'devolvidas')::int = 1);
  select jsonb_build_object('teste','opt_out_segue_com_humano','ok', status = 'aguardando_humano') into r from public.conversas where id = conv;
  res := res || r;

  raise exception 'RESULTADO % de % ok: %',
    (select count(*) from jsonb_array_elements(res) e where (e->>'ok')::boolean), jsonb_array_length(res),
    (select jsonb_agg(e->>'teste') from jsonb_array_elements(res) e where not (e->>'ok')::boolean);
end;
$$;
