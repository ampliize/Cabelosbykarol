-- Teste: retorno em 3 min, encaminhamento ao responsável e dashboard.
-- Termina com RAISE EXCEPTION (desfaz tudo); resultado esperado: "RESULTADO 12 de 12 ok: <NULL>".
do $$
declare
  res jsonb := '[]'::jsonb; r jsonb; c1 uuid; c2 uuid; c3 uuid; n int;
begin
  update public.config_bot set valor = '["5511900000001","5511900000002","5511900000003"]' where chave = 'whitelist_piloto';
  insert into public.equipe (nome, telefone, papel, recebe_handoff) values ('Recepcao Teste', '5511900000009', 'recepcao', true);
  insert into public.equipe (nome, telefone, papel, recebe_alertas_sistema) values ('Ampliize Teste', '5511900000008', 'ampliize', true);

  select jsonb_object_agg(chave, valor) into r from public.config_bot
   where chave in ('devolver_ao_bot_apos_minutos','minutos_espera_handoff','minutos_tolerancia_resposta_humana');
  res := res || jsonb_build_object('teste','config_3min','ok', r = '{"devolver_ao_bot_apos_minutos":3,"minutos_espera_handoff":3,"minutos_tolerancia_resposta_humana":3}'::jsonb);

  r := public.registrar_mensagem_entrada('E-1','5511900000001',false,'text','oi',null,'Ju'); c1 := (r->>'conversa_id')::uuid;
  perform public.registrar_mensagem_entrada('E-2','5511900000001',true,'text','oi Ju, aqui e a Karol');
  select jsonb_build_object('teste','humano_3min','ok', round(extract(epoch from pausado_ate - now())/60) = 3) into r from public.conversas where id = c1;
  res := res || r;

  r := public.registrar_mensagem_entrada('E-3','5511900000002',false,'text','Meu cabelo ficou horrivel',null,'Ana'); c2 := (r->>'conversa_id')::uuid;
  r := public.iniciar_handoff(c2, 'reclamacao', 'Cliente insatisfeita com progressiva');
  res := res || jsonb_build_object('teste','reclamacao_volta_3min','ok', (r->>'retorno_automatico')::boolean
        and round(extract(epoch from (r->>'bot_volta_em')::timestamptz - now())/60) = 3);
  select jsonb_build_object('teste','encaminhou_transferencia','ok', tipo = 'transferencia' and jsonb_array_length(destinatarios) = 1
        and mensagem_cliente = 'Meu cabelo ficou horrivel' and estado = 'pendente') into r
    from public.notificacoes_equipe where conversa_id = c2 order by id desc limit 1;
  res := res || r;

  r := public.registrar_mensagem_entrada('E-4','5511900000003',false,'text','Posso fazer progressiva gravida?',null,'Pat'); c3 := (r->>'conversa_id')::uuid;
  perform public.iniciar_handoff(c3, 'incerteza', 'Pergunta sobre gestacao');
  select jsonb_build_object('teste','duvida_agente','ok', tipo = 'duvida_agente') into r
    from public.notificacoes_equipe where conversa_id = c3 order by id desc limit 1;
  res := res || r;

  update public.conversas set pausado_ate = now() - interval '10 seconds' where id in (c2, c3);
  r := public.devolver_conversas_ao_bot();
  res := res || jsonb_build_object('teste','cron_devolve_2','ok', (r->>'devolvidas')::int = 2);
  select count(*) into n from public.notificacoes_equipe where tipo = 'sem_resposta_humana' and conversa_id in (c2, c3);
  res := res || jsonb_build_object('teste','alerta_sem_resposta','ok', n = 2);
  select jsonb_build_object('teste','status_volta_bot','ok', bool_and(status = 'bot')) into r from public.conversas where id in (c2, c3);
  res := res || r;

  perform public.iniciar_handoff(c1, 'opt_out', 'Nao quer robo');
  select jsonb_build_object('teste','opt_out_nao_volta','ok', pausado_ate is null and bot_desativado) into r from public.conversas where id = c1;
  res := res || r;

  r := public.encaminhar_para_responsavel('erro_sistema', null, 'belasis_503', 'API Belasis fora do ar');
  res := res || jsonb_build_object('teste','erro_sistema_destinatarios','ok', jsonb_array_length(r->'destinatarios') = 2);
  perform public.marcar_notificacao((r->>'notificacao_id')::bigint, true);
  select jsonb_build_object('teste','marcar_enviada','ok', estado = 'enviada' and enviado_em is not null) into r
    from public.notificacoes_equipe where id = (r->>'notificacao_id')::bigint;
  res := res || r;

  r := public.dashboard_dados(7);
  res := res || jsonb_build_object('teste','dashboard','ok',
     (r->'kpis'->>'conversas')::int >= 3 and (r->'kpis'->>'transferencias')::int >= 3
     and (r->'kpis'->>'encaminhamentos')::int >= 6 and jsonb_array_length(r->'serie_diaria') = 7
     and jsonb_array_length(r->'motivos_transferencia') >= 3 and (r->>'minutos_retorno')::int = 3);

  raise exception 'RESULTADO % de % ok: %',
    (select count(*) from jsonb_array_elements(res) e where (e->>'ok')::boolean), jsonb_array_length(res),
    (select jsonb_agg(e->>'teste') from jsonb_array_elements(res) e where not coalesce((e->>'ok')::boolean, false));
end;
$$;
