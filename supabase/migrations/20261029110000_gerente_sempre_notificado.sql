-- Toda transferência / dúvida do agente também avisa a gerência (config gerentes_notificados),
-- além de quem está de plantão (recepção no expediente; fora dele, a escala 24h).
insert into public.config_bot (chave, valor, descricao) values
  ('gerentes_notificados', '["5579999216161"]'::jsonb, 'Telefones da gerência que recebem TODA transferência/dúvida do agente, além de quem está de plantão')
on conflict (chave) do nothing;

create or replace function public.destinatarios_encaminhamento(p_tipo text, p_em timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_aberto boolean := public.salao_aberto(p_em);
  v_min    integer;
  v_dest   jsonb;
  v_ger    jsonb;
begin
  if jsonb_typeof(public.cfg('encaminhar_somente_para')) = 'array'
     and jsonb_array_length(public.cfg('encaminhar_somente_para')) > 0 then
    select jsonb_agg(jsonb_build_object('nome', 'Teste', 'telefone', t))
      into v_dest
      from jsonb_array_elements_text(public.cfg('encaminhar_somente_para')) t;
    return v_dest;
  end if;

  if p_tipo = 'erro_sistema' then
    select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone) order by e.prioridade), '[]')
      into v_dest
      from public.equipe e where e.ativo and e.recebe_alertas_sistema;
    return v_dest;
  end if;

  select min(e.prioridade) into v_min
    from public.equipe e
   where e.ativo and e.recebe_handoff and (e.disponibilidade = '24h' or v_aberto);

  if p_tipo = 'sem_resposta_humana' then
    select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone) order by e.prioridade), '[]')
      into v_dest
      from public.equipe e
     where e.ativo and e.recebe_handoff and (e.disponibilidade = '24h' or v_aberto)
       and e.prioridade = (select min(x.prioridade) from public.equipe x
                            where x.ativo and x.recebe_handoff and x.prioridade > v_min
                              and (x.disponibilidade = '24h' or v_aberto));
  end if;

  if v_dest is null or jsonb_array_length(v_dest) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone)), '[]')
      into v_dest
      from public.equipe e
     where e.ativo and e.recebe_handoff and e.prioridade = v_min
       and (e.disponibilidade = '24h' or v_aberto);
  end if;

  -- gerência recebe toda transferência e dúvida do agente (sem duplicar quem já está na lista)
  if p_tipo in ('transferencia', 'duvida_agente', 'sem_resposta_humana') then
    select coalesce(jsonb_agg(jsonb_build_object('nome', coalesce(e.nome, 'Gerência'), 'telefone', g.tel)), '[]')
      into v_ger
      from jsonb_array_elements_text(coalesce(public.cfg('gerentes_notificados'), '[]')) g(tel)
      left join public.equipe e on e.telefone = g.tel
     where not exists (select 1 from jsonb_array_elements(v_dest) d where d->>'telefone' = g.tel);
    v_dest := v_dest || v_ger;
  end if;
  return v_dest;
end;
$function$;
