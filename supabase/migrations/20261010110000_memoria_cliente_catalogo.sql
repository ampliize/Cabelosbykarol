-- =====================================================================
-- Memória da cliente e catálogo para o agente, a partir da cópia local do
-- Belasis (sem chamar a API durante a conversa).
-- =====================================================================

-- Variações do telefone (com e sem o 9º dígito) para casar com o cadastro.
create or replace function public.variantes_telefone(p_tel text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_remove(array[
    d,
    case when length(d) = 13 then left(d, 4) || right(d, 8) end,                 -- sem o 9
    case when length(d) = 12 then left(d, 4) || '9' || right(d, 8) end           -- com o 9
  ], null)
  from (select regexp_replace(coalesce(p_tel, ''), '\D', '', 'g') as d) t;
$$;

create or replace function public.perfil_cliente_belasis(p_telefone text)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  hoje date := (now() at time zone 'America/Maceio')::date;
  c    public.belasis_clientes;
  v_n  integer;
begin
  select count(*) into v_n from public.belasis_clientes where telefones && public.variantes_telefone(p_telefone);
  select bc.* into c
    from public.belasis_clientes bc
   where bc.telefones && public.variantes_telefone(p_telefone)
   order by (select max(a.data) from public.belasis_agendamentos a where a.cliente_id = bc.id) desc nulls last, bc.id desc
   limit 1;
  if c.id is null then
    return jsonb_build_object('cadastrada', false);
  end if;

  return jsonb_build_object(
    'cadastrada', true,
    'belasis_cliente_id', c.id,
    'primeiro_nome', c.primeiro_nome,
    'cadastros_com_este_telefone', v_n,
    'aniversario', to_char(c.aniversario, 'DD/MM'),
    'aniversario_hoje', c.aniversario is not null and to_char(c.aniversario, 'MMDD') = to_char(hoje, 'MMDD'),
    'visitas_ultimos_120_dias', (select count(*) from public.belasis_agendamentos a
                                  where a.cliente_id = c.id and a.data <= hoje and a.status <> 'disconfirm'),
    'ultimos_atendimentos', (select coalesce(jsonb_agg(x order by x->>'data' desc), '[]') from (
        select jsonb_build_object('data', to_char(a.data, 'DD/MM/YYYY'), 'status', a.status,
          'servicos', (select jsonb_agg(jsonb_build_object('servico', s.descricao, 'profissional', p.nome))
                         from jsonb_array_elements(a.itens) it
                         left join public.belasis_servicos s on s.id = (it->>'servico_id')::int
                         left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int)) x
          from public.belasis_agendamentos a
         where a.cliente_id = c.id and a.data <= hoje and a.status <> 'disconfirm'
         order by a.data desc limit 5) y),
    'proximos_agendamentos', (select coalesce(jsonb_agg(x), '[]') from (
        select jsonb_build_object('data', to_char(a.data, 'DD/MM/YYYY'), 'status', a.status,
          'itens', (select jsonb_agg(jsonb_build_object('servico', s.descricao, 'profissional', p.nome, 'inicio', it->>'inicio'))
                      from jsonb_array_elements(a.itens) it
                      left join public.belasis_servicos s on s.id = (it->>'servico_id')::int
                      left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int)) x
          from public.belasis_agendamentos a
         where a.cliente_id = c.id and a.data >= hoje and a.status <> 'disconfirm'
         order by a.data limit 3) y),
    'profissional_mais_frequente', (select p.nome from public.belasis_agendamentos a,
          jsonb_array_elements(a.itens) it join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int
         where a.cliente_id = c.id and a.status <> 'disconfirm'
         group by p.nome order by count(*) desc, max(a.data) desc limit 1),
    'servico_mais_frequente', (select s.descricao from public.belasis_agendamentos a,
          jsonb_array_elements(a.itens) it join public.belasis_servicos s on s.id = (it->>'servico_id')::int
         where a.cliente_id = c.id and a.status <> 'disconfirm'
         group by s.descricao order by count(*) desc, max(a.data) desc limit 1),
    'faltas_ou_cancelamentos', (select count(*) from public.belasis_agendamentos a where a.cliente_id = c.id and a.status = 'disconfirm')
  );
end;
$$;

-- Catálogo de serviços (para o agente responder serviço/preço/duração/quem faz).
create or replace function public.consultar_servicos(p_busca text, p_limite integer default 8)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with termos as (
    select t from regexp_split_to_table(lower(extensions.unaccent(coalesce(p_busca, ''))), '[^a-z0-9]+') t where length(t) >= 3
  ), cand as (
    select s.*, (select count(*) from termos where lower(extensions.unaccent(s.descricao)) like '%' || termos.t || '%') acertos
      from public.belasis_servicos s
     where s.ativo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'servico', descricao,
           'preco_tabela', case when preco_cents > 0 then to_char(preco_cents / 100.0, 'FM"R$ "999G990D00') end,
           'duracao_min', duracao_min,
           'agendamento_online', online,
           'profissionais', (select jsonb_agg(p.nome order by p.nome) from public.belasis_profissional_servicos v
                              join public.belasis_profissionais p on p.id = v.profissional_id and p.ativo
                             where v.servico_id = cand.id and v.ativo))
         order by acertos desc, descricao), '[]')
    from (select * from cand where acertos > 0 order by acertos desc, descricao limit greatest(1, least(p_limite, 15))) cand;
$$;

-- Ressincroniza todo dia às 05:30 (Aracaju), só leitura, se o Belasis não estiver desligado.
select cron.schedule('belasis-sync-diario', '30 8 * * *',
  $$select case when coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado') <> 'desligado'
                then public.belasis_iniciar_sync(120, 45) end$$);

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('variantes_telefone','perfil_cliente_belasis','consultar_servicos')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
