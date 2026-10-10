-- Painel: dados do salão vindos do Belasis (somente leitura, mesmo controle de acesso
-- do dashboard_dados: só e-mails em painel_usuarios).
create or replace function public.dashboard_belasis(p_dias integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_role  text := coalesce(auth.jwt() ->> 'role', '');
  hoje    date := (now() at time zone 'America/Maceio')::date;
  ini     date;
begin
  if v_role <> 'service_role' and session_user not in ('postgres', 'supabase_admin')
     and not exists (select 1 from public.painel_usuarios u where lower(u.email) = v_email) then
    raise exception 'acesso_negado' using errcode = '42501';
  end if;
  p_dias := least(greatest(coalesce(p_dias, 30), 1), 120);
  ini := hoje - (p_dias - 1);

  return jsonb_build_object(
    'sincronizado_em', (select max(atualizado_em) from public.belasis_agendamentos),
    'fila_pendente', (select count(*) from public.belasis_fila where estado in ('pendente','processando')),
    'modo', public.cfg('belasis_modo') #>> '{}',
    'totais', jsonb_build_object(
      'clientes', (select count(*) from public.belasis_clientes),
      'clientes_com_whatsapp', (select count(*) from public.belasis_clientes where cardinality(telefones) > 0),
      'servicos_ativos', (select count(*) from public.belasis_servicos where ativo),
      'servicos_online', (select count(*) from public.belasis_servicos where ativo and online),
      'profissionais', (select count(*) from public.belasis_profissionais where ativo)),
    'periodo', (select jsonb_build_object(
        'agendamentos', count(*),
        'confirmados', count(*) filter (where status = 'confirmed'),
        'nao_confirmados', count(*) filter (where status = 'unconfirmed'),
        'cancelados_ou_faltas', count(*) filter (where status = 'disconfirm'),
        'chegaram', count(*) filter (where status = 'waiting'),
        'clientes_distintas', count(distinct cliente_id),
        'clientes_recorrentes', (select count(*) from (select cliente_id from public.belasis_agendamentos
                                   where data between ini and hoje and status <> 'disconfirm'
                                   group by cliente_id having count(*) >= 2) r))
      from public.belasis_agendamentos where data between ini and hoje),
    'proximos_7_dias', (select jsonb_build_object(
        'agendamentos', count(*) filter (where status <> 'disconfirm'),
        'nao_confirmados', count(*) filter (where status = 'unconfirmed'))
      from public.belasis_agendamentos where data between hoje and hoje + 7),
    'por_dia', (select coalesce(jsonb_agg(jsonb_build_object('dia', d, 'total', t, 'cancelados', c) order by d), '[]')
      from (select g::date d,
                   (select count(*) from public.belasis_agendamentos a where a.data = g::date and a.status <> 'disconfirm') t,
                   (select count(*) from public.belasis_agendamentos a where a.data = g::date and a.status = 'disconfirm') c
              from generate_series(ini, hoje + 7, interval '1 day') g) x),
    'top_servicos', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'total', total, 'preco', preco) order by total desc), '[]')
      from (select coalesce(s.descricao, 'Serviço ' || i.sid) nome, count(*) total, s.preco_cents / 100.0 preco
              from (select (it->>'servico_id')::int sid from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                     where a.data between ini and hoje and a.status <> 'disconfirm') i
              left join public.belasis_servicos s on s.id = i.sid
             group by 1, 3 order by 2 desc limit 12) x),
    'por_profissional', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'total', total) order by total desc), '[]')
      from (select coalesce(p.nome, 'Profissional ' || i.pid) nome, count(*) total
              from (select (it->>'profissional_id')::int pid from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                     where a.data between ini and hoje and a.status <> 'disconfirm') i
              left join public.belasis_profissionais p on p.id = i.pid
             group by 1 order by 2 desc limit 15) x),
    'ocupacao_proximos_dias', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'ocupacao', ocup, 'livres', livres) order by ocup desc), '[]')
      from (select p.nome,
                   round(100.0 * sum((select count(*) from jsonb_array_elements(h.slots) s where s->>'label' <> 'available'))
                         / nullif(sum(jsonb_array_length(h.slots)), 0)) ocup,
                   sum((select count(*) from jsonb_array_elements(h.slots) s where s->>'label' = 'available')) livres
              from public.belasis_horarios_livres h join public.belasis_profissionais p on p.id = h.profissional_id
             where h.data > hoje and p.ativo
             group by p.nome) x where ocup is not null),
    'pre_agendamentos', (select coalesce(jsonb_agg(jsonb_build_object('criado_em', criado_em, 'servico', servico,
                            'profissional', profissional, 'data', data, 'hora', to_char(hora_inicio, 'HH24:MI'), 'estado', estado)
                            order by criado_em desc), '[]')
      from (select * from public.pre_agendamentos order by criado_em desc limit 10) x),
    'chamadas_api_24h', (select jsonb_build_object('total', count(*), 'erros', count(*) filter (where status_http not between 200 and 299))
      from public.belasis_chamadas where criado_em > now() - interval '24 hours')
  );
end;
$$;

revoke all on function public.dashboard_belasis(integer) from public, anon;
grant execute on function public.dashboard_belasis(integer) to authenticated, service_role;
