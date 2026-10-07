-- Teste: modos do Belasis (desligado → varredura → leitura → escrita), log,
-- 429, catálogo da varredura e pré-agendamento.
-- Termina com RAISE EXCEPTION (desfaz tudo); esperado: "RESULTADO 16 de 16 ok".
do $$
declare
  res jsonb := '[]'::jsonb; r jsonb; c1 uuid; n int;
begin
  -- 1. desligado (padrão)
  r := public.autorizar_chamada_belasis('GET', '/employees', 'varredura');
  res := res || jsonb_build_object('teste','desligado_bloqueia','ok', not (r->>'permitido')::boolean and r->>'motivo' = 'belasis_desligado');

  -- 2. varredura
  update public.config_bot set valor = '"varredura"' where chave = 'belasis_modo';
  r := public.autorizar_chamada_belasis('GET', '/employees', 'agente');
  res := res || jsonb_build_object('teste','varredura_bloqueia_agente','ok', r->>'motivo' = 'modo_varredura_so_permite_varredura');
  r := public.autorizar_chamada_belasis('get', '/employees/12/free_times?date=2026-10-08', 'varredura');
  res := res || jsonb_build_object('teste','varredura_libera_get','ok', (r->>'permitido')::boolean and r->>'rota' = '/employees/{id}/free_times'
        and r->>'base_url' = 'https://api.belasis.com.br/api/v1');
  r := public.autorizar_chamada_belasis('POST', '/schedule_groups', 'varredura');
  res := res || jsonb_build_object('teste','varredura_bloqueia_post','ok', r->>'motivo' = 'escrita_bloqueada_no_modo_varredura');

  -- 3. leitura
  update public.config_bot set valor = '"leitura"' where chave = 'belasis_modo';
  r := public.autorizar_chamada_belasis('GET', '/clients', 'agente');
  res := res || jsonb_build_object('teste','leitura_libera_get_agente','ok', (r->>'permitido')::boolean);
  r := public.autorizar_chamada_belasis('POST', '/schedule_groups', 'agente');
  res := res || jsonb_build_object('teste','leitura_bloqueia_post','ok', r->>'motivo' = 'escrita_bloqueada_no_modo_leitura');
  r := public.autorizar_chamada_belasis('PATCH', '/schedule_groups/55/cancel', 'agente');
  res := res || jsonb_build_object('teste','leitura_bloqueia_cancelar','ok', not (r->>'permitido')::boolean);

  -- 4. escrita (só lista branca, DELETE nunca)
  update public.config_bot set valor = '"escrita"' where chave = 'belasis_modo';
  r := public.autorizar_chamada_belasis('POST', '/schedule_groups', 'agente');
  res := res || jsonb_build_object('teste','escrita_libera_agendar','ok', (r->>'permitido')::boolean);
  r := public.autorizar_chamada_belasis('PATCH', '/schedule_groups/55/cancel', 'agente');
  res := res || jsonb_build_object('teste','escrita_libera_cancelar','ok', (r->>'permitido')::boolean);
  r := public.autorizar_chamada_belasis('DELETE', '/schedule_groups/55', 'agente');
  res := res || jsonb_build_object('teste','delete_sempre_proibido','ok', r->>'motivo' = 'metodo_proibido');
  r := public.autorizar_chamada_belasis('PATCH', '/inventory/services/3', 'agente');
  res := res || jsonb_build_object('teste','rota_fora_lista_branca','ok', r->>'motivo' = 'rota_fora_da_lista_branca');

  -- 5. log + 429
  select count(*) into n from public.belasis_chamadas where criado_em >= now();
  res := res || jsonb_build_object('teste','tudo_logado','ok', n = 11);
  perform public.registrar_chamada_belasis((r->>'log_id')::bigint, 429, 120, 'Too Many Requests');
  select chamadas into n from public.rate_limit where recurso = 'belasis' and janela = date_trunc('minute', clock_timestamp());
  res := res || jsonb_build_object('teste','429_esgota_minuto','ok', n >= 100000);

  -- 6. catálogo da varredura
  perform public.salvar_varredura_belasis('{"ok":true}',
    '[{"id":9001,"description":"Progressiva","price_cents":25000,"duration":180,"active":true,"available_to_online_scheduling":true},
      {"id":9002,"description":"Corte","price_cents":8000,"duration":45,"active":true,"available_to_online_scheduling":false}]',
    '[{"id":8001,"name":"Ana"}]',
    '[{"profissional_id":8001,"servico_id":9001},{"profissional_id":8001,"servico_id":9002}]');
  perform public.salvar_varredura_belasis('{"ok":true}',
    '[{"id":9001,"description":"Progressiva","price_cents":26000,"duration":180,"active":true,"available_to_online_scheduling":true}]',
    '[{"id":8001,"name":"Ana"}]',
    '[{"profissional_id":8001,"servico_id":9001}]');
  select count(*) filter (where ativo) into n from public.belasis_servicos where id in (9001, 9002);
  res := res || jsonb_build_object('teste','varredura_inativa_sumidos','ok', n = 1
        and (select preco_cents from public.belasis_servicos where id = 9001) = 26000
        and (select count(*) from public.belasis_profissional_servicos where profissional_id = 8001 and ativo) = 1);

  -- 7. pré-agendamento
  insert into public.conversas (telefone, nome, belasis_cliente_id) values ('5511900000077', 'Ju Teste', 321) returning id into c1;
  r := public.criar_pre_agendamento(c1, 'Progressiva', '2026-10-09', '09:00', 'Ana', 9001, 8001, null, 'Pode sim!');
  res := res || jsonb_build_object('teste','pre_agendamento_calcula_fim','ok', r->>'hora_fim' = '12:00:00'
        and (select belasis_cliente_id from public.pre_agendamentos where id = (r->>'pre_agendamento_id')::bigint) = 321);
  select count(*) into n from public.notificacoes_equipe where conversa_id = c1 and tipo = 'pre_agendamento'
     and resumo like 'Pedido: Progressiva com Ana — 09/10%às 09:00 até 12:00%NÃO CONFIRMADO%';
  res := res || jsonb_build_object('teste','pre_agendamento_avisa_equipe','ok', n = 1);

  select count(*) filter (where (x->>'ok')::boolean) into n from jsonb_array_elements(res) x;
  raise exception 'RESULTADO % de % ok: %', n, jsonb_array_length(res),
    (select jsonb_agg(x->>'teste') from jsonb_array_elements(res) x where not (x->>'ok')::boolean);
end;
$$;
