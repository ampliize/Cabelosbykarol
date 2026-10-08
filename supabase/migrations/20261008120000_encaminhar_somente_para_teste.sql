-- MODO TESTE: durante os testes, todos os avisos vão só para os números em
-- config_bot.encaminhar_somente_para (a equipe real não recebe nada).
insert into public.config_bot (chave, valor, descricao) values
  ('encaminhar_somente_para', 'null',
   'MODO TESTE: lista de telefones. Se preenchida, TODOS os avisos vão só para esses números (a equipe real não recebe). null = normal.')
on conflict (chave) do nothing;

do $$
declare
  v_def text := pg_get_functiondef('public.destinatarios_encaminhamento(text,timestamptz)'::regprocedure);
  v_old text := 'begin
  if p_tipo = ''erro_sistema'' then';
  v_new text := 'begin
  if jsonb_typeof(public.cfg(''encaminhar_somente_para'')) = ''array''
     and jsonb_array_length(public.cfg(''encaminhar_somente_para'')) > 0 then
    select jsonb_agg(jsonb_build_object(''nome'', ''Teste'', ''telefone'', t))
      into v_dest
      from jsonb_array_elements_text(public.cfg(''encaminhar_somente_para'')) t;
    return v_dest;
  end if;

  if p_tipo = ''erro_sistema'' then';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'trecho não encontrado em destinatarios_encaminhamento';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$$;
