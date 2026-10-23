-- Painel: agenda réplica do Belasis (com filtros) e ranking por período.
-- Mesma regra de acesso do painel (painel_usuarios); só primeiro nome da cliente.

create or replace function public.painel_autorizado()
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(auth.jwt() ->> 'role', '') = 'service_role'
      or session_user in ('postgres', 'supabase_admin')
      or exists (select 1 from public.painel_usuarios u where lower(u.email) = lower(coalesce(auth.jwt() ->> 'email', '')));
$function$;

-- Profissional que "atende": ativa, não é recepção/secretaria/Ateliê e tem agenda
-- (atendimento nos últimos 60 dias, agendamento futuro ou horário livre na grade) — inclui recém-cadastradas.
create or replace function public.belasis_profissionais_que_atendem()
returns setof integer
language sql
stable
set search_path to ''
as $function$
  select p.id
    from public.belasis_profissionais p
   where p.ativo and p.nome <> 'Ateliê' and coalesce(p.profissao, '') !~* 'recep|secret'
     and (exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                   where (it->>'profissional_id')::int = p.id and a.status <> 'removido'
                     and a.data >= (now() at time zone 'America/Maceio')::date - 60)
          or exists (select 1 from public.belasis_horarios_livres h, jsonb_array_elements(h.slots) s
                      where h.profissional_id = p.id and h.data >= (now() at time zone 'America/Maceio')::date
                        and s->>'label' = 'available'));
$function$;

create or replace function public.dashboard_agenda(p_ini date, p_fim date, p_profissional integer default null, p_status text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_fim date := least(coalesce(p_fim, p_ini), coalesce(p_ini, p_fim) + 62);
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return jsonb_build_object(
    'sincronizado_em', (select max(atualizado_em) from public.belasis_agendamentos),
    'profissionais', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id,
                        'nome', public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome)) order by p.nome), '[]')
                        from public.belasis_profissionais p where p.id in (select public.belasis_profissionais_que_atendem())),
    'itens', (select coalesce(jsonb_agg(x order by x->>'data', x->>'inicio', x->>'profissional'), '[]') from (
      select jsonb_build_object(
               'id', a.id, 'data', a.data, 'inicio', it->>'inicio', 'fim', it->>'fim',
               'status', a.status,
               'cliente', coalesce(nullif(c.primeiro_nome, ''), 'Cliente'),
               'servico', coalesce(s.descricao, 'Serviço ' || (it->>'servico_id')),
               'categoria', g.nome,
               'preco', s.preco_cents / 100.0,
               'profissional_id', (it->>'profissional_id')::int,
               'profissional', coalesce(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome), '?'),
               'ia', coalesce(a.observacao, '') ilike 'Pré-agendamento pelo WhatsApp%') x
        from public.belasis_agendamentos a
        cross join lateral jsonb_array_elements(a.itens) it
        left join public.belasis_clientes c on c.id = a.cliente_id
        left join public.belasis_servicos s on s.id = (it->>'servico_id')::int
        left join public.belasis_grupos g on g.id = s.group_id
        left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int
       where a.data between p_ini and v_fim and a.status <> 'removido'
         and (p_profissional is null or (it->>'profissional_id')::int = p_profissional)
         and (p_status is null or a.status = p_status)) q)
  );
end;
$function$;

-- faturamento = soma do preço de tabela dos serviços (a API não informa o valor cobrado)
create or replace function public.dashboard_ranking(p_ini date, p_fim date)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return (
    with itens as (
      select a.id ag, a.cliente_id, a.status, a.data, (it->>'servico_id')::int sid, (it->>'profissional_id')::int pid,
             coalesce(s.preco_cents, 0) / 100.0 preco, s.descricao, g.nome categoria
        from public.belasis_agendamentos a
        cross join lateral jsonb_array_elements(a.itens) it
        left join public.belasis_servicos s on s.id = (it->>'servico_id')::int
        left join public.belasis_grupos g on g.id = s.group_id
       where a.data between p_ini and p_fim and a.status <> 'removido'
    ), ok as (select * from itens where status <> 'disconfirm')
    select jsonb_build_object(
      'periodo', jsonb_build_object('ini', p_ini, 'fim', p_fim),
      'resumo', (select jsonb_build_object('atendimentos', count(distinct ag), 'servicos', count(*),
                   'faturamento_estimado', round(sum(preco), 2), 'clientes', count(distinct cliente_id),
                   'ticket_medio', round(sum(preco) / nullif(count(distinct ag), 0), 2),
                   'cancelados', (select count(distinct ag) from itens where status = 'disconfirm'),
                   'pelo_whatsapp', (select count(*) from public.belasis_agendamentos a
                                      where a.data between p_ini and p_fim and a.status <> 'removido'
                                        and coalesce(a.observacao, '') ilike 'Pré-agendamento pelo WhatsApp%'))
                 from ok),
      'profissionais', (select coalesce(jsonb_agg(r order by (r->>'faturamento')::numeric desc), '[]') from (
          select jsonb_build_object('nome', coalesce(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome), 'Profissional ' || i.pid),
                   'atendimentos', count(distinct i.ag) filter (where i.status <> 'disconfirm'),
                   'servicos', count(*) filter (where i.status <> 'disconfirm'),
                   'clientes', count(distinct i.cliente_id) filter (where i.status <> 'disconfirm'),
                   'faturamento', round(coalesce(sum(i.preco) filter (where i.status <> 'disconfirm'), 0), 2),
                   'ticket_medio', round(coalesce(sum(i.preco) filter (where i.status <> 'disconfirm'), 0)
                                   / nullif(count(distinct i.ag) filter (where i.status <> 'disconfirm'), 0), 2),
                   'cancelados', count(distinct i.ag) filter (where i.status = 'disconfirm')) r
            from itens i left join public.belasis_profissionais p on p.id = i.pid
           where coalesce(p.nome, '') <> 'Ateliê'
           group by i.pid, p.apelido, p.apelido_belasis, p.nome) x),
      'servicos', (select coalesce(jsonb_agg(r order by (r->>'qtd')::int desc), '[]') from (
          select jsonb_build_object('nome', coalesce(descricao, 'Serviço ' || sid), 'categoria', categoria,
                   'qtd', count(*), 'faturamento', round(sum(preco), 2)) r
            from ok group by sid, descricao, categoria order by count(*) desc limit 25) x),
      'categorias', (select coalesce(jsonb_agg(r order by (r->>'faturamento')::numeric desc), '[]') from (
          select jsonb_build_object('nome', coalesce(categoria, 'Sem categoria'), 'qtd', count(*), 'faturamento', round(sum(preco), 2)) r
            from ok group by categoria) x),
      'clientes', (select coalesce(jsonb_agg(r order by (r->>'visitas')::int desc, (r->>'gasto')::numeric desc), '[]') from (
          select jsonb_build_object('nome', coalesce(nullif(c.primeiro_nome, ''), 'Cliente'),
                   'visitas', count(distinct o.ag), 'gasto', round(sum(o.preco), 2), 'ultima', max(o.data),
                   'profissional', (select public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome)
                                      from ok o2 join public.belasis_profissionais p on p.id = o2.pid
                                     where o2.cliente_id = o.cliente_id group by p.id order by count(*) desc limit 1)) r
            from ok o left join public.belasis_clientes c on c.id = o.cliente_id
           where o.data <= (now() at time zone 'America/Maceio')::date
           group by o.cliente_id, c.primeiro_nome
           order by count(distinct o.ag) desc, sum(o.preco) desc limit 30) x)
    ) from (select 1) one
  );
end;
$function$;

-- pré-agendamentos no painel com a situação da escrita automática
do $$
declare d text;
begin
  d := pg_get_functiondef('public.dashboard_belasis(integer)'::regprocedure);
  if position('escrita_estado' in d) = 0 then
    d := replace(d, $x$'hora', to_char(hora_inicio, 'HH24:MI'), 'estado', estado)$x$,
                    $x$'hora', to_char(hora_inicio, 'HH24:MI'), 'estado', estado, 'escrita', escrita_estado, 'erro', escrita_erro)$x$);
    if position('escrita_estado' in d) = 0 then raise exception 'dashboard_belasis: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

grant execute on function public.dashboard_agenda(date, date, integer, text) to authenticated;
grant execute on function public.dashboard_ranking(date, date) to authenticated;
