-- 1) Últimos atendimentos ordenados pela data real.
-- 2) "Quem faz" = quem realizou o serviço nos agendamentos (últimos 120 dias);
--    o cadastro de serviços por profissional do Belasis não reflete a prática.
do $$
declare
  v_def text := pg_get_functiondef('public.perfil_cliente_belasis(text)'::regprocedure);
begin
  v_def := replace(v_def,
    $o$'ultimos_atendimentos', (select coalesce(jsonb_agg(x order by x->>'data' desc), '[]') from ($o$,
    $n$'ultimos_atendimentos', (select coalesce(jsonb_agg(x order by ord desc), '[]') from ($n$);
  v_def := replace(v_def,
    $o$                         left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int)) x
          from public.belasis_agendamentos a
         where a.cliente_id = c.id and a.data <= hoje$o$,
    $n$                         left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int)) x, a.data ord
          from public.belasis_agendamentos a
         where a.cliente_id = c.id and a.data <= hoje$n$);
  if position('a.data ord' in v_def) = 0 then raise exception 'perfil: trecho não encontrado'; end if;
  execute v_def;
end $$;

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
  ), realizados as (
    select (it->>'servico_id')::int sid, split_part(p.nome, ' ', 1) nome, count(*) n
      from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
      join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int and p.ativo
     where a.status <> 'disconfirm' and a.data >= current_date - 120 and p.nome <> 'Ateliê'
     group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'servico', descricao,
           'preco_tabela', case when preco_cents > 0 then 'R$ ' || replace(to_char(preco_cents / 100.0, 'FM999990.00'), '.', ',') end,
           'duracao_min', duracao_min,
           'agendamento_online', online,
           'quem_faz', (select jsonb_agg(r.nome order by r.n desc) from realizados r where r.sid = cand.id),
           'feitos_ultimos_120_dias', (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id))
         order by acertos desc, (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id) desc, descricao), '[]')
    from (select * from cand where acertos > 0
           order by acertos desc, (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id) desc, descricao
           limit greatest(1, least(p_limite, 15))) cand;
$$;
revoke all on function public.consultar_servicos(text, integer) from public, anon, authenticated;
grant execute on function public.consultar_servicos(text, integer) to service_role;
