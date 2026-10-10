-- consultar_servicos: devolve a categoria do Belasis e também encontra o serviço
-- pelo nome da categoria (ex.: "alongamento", "tratamento", "química").
create or replace function public.consultar_servicos(p_busca text, p_limite integer default 8)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  with termos as (
    select t from regexp_split_to_table(lower(extensions.unaccent(coalesce(p_busca, ''))), '[^a-z0-9]+') t where length(t) >= 3
  ), cand as (
    select s.*, g.nome categoria,
           (select count(*) from termos where lower(extensions.unaccent(s.descricao)) like '%' || termos.t || '%') * 2
         + (select count(*) from termos where lower(extensions.unaccent(coalesce(g.nome, ''))) like '%' || termos.t || '%') acertos
      from public.belasis_servicos s
      left join public.belasis_grupos g on g.id = s.group_id
     where s.ativo
  ), realizados as (
    select (it->>'servico_id')::int sid, public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) nome, count(*) n
      from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
      join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int and p.ativo
     where a.status not in ('disconfirm', 'removido') and a.data >= current_date - 120 and p.nome <> 'Ateliê'
     group by 1, 2
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'servico', descricao,
           'categoria', categoria,
           'preco_tabela', case when preco_cents > 0 then 'R$ ' || replace(to_char(preco_cents / 100.0, 'FM999990.00'), '.', ',') end,
           'duracao_min', duracao_min,
           'agendamento_online', online,
           'quem_faz', (select jsonb_agg(r.nome order by r.n desc) from realizados r where r.sid = cand.id),
           'feitos_ultimos_120_dias', (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id))
         order by acertos desc, (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id) desc, descricao), '[]')
    from (select * from cand where acertos > 0
           order by acertos desc, (select coalesce(sum(r.n), 0) from realizados r where r.sid = cand.id) desc, descricao
           limit greatest(1, least(p_limite, 15))) cand;
$function$;
