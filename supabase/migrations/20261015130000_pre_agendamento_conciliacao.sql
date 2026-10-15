-- Etapa A: pré-agendamento vira "lancado" sozinho quando a recepção lança no Belasis
-- (cruza telefone da cliente + data + horário com a agenda sincronizada). Só leitura no Belasis.
alter table public.pre_agendamentos
  add column if not exists belasis_agendamento_id integer,
  add column if not exists lancado_em timestamptz;

create or replace function public.belasis_conciliar_pre_agendamentos()
returns integer
language plpgsql
set search_path to ''
as $function$
declare v_n integer;
begin
  with achados as (
    select distinct on (p.id) p.id, a.id ag_id
      from public.pre_agendamentos p
      join public.conversas c on c.id = p.conversa_id
      join public.belasis_clientes bc on bc.telefones && public.variantes_telefone(c.telefone)
      join public.belasis_agendamentos a on a.cliente_id = bc.id and a.data = p.data
                                        and a.status not in ('disconfirm', 'removido')
     where p.estado = 'pendente'
       and p.data >= current_date - 1
       and exists (select 1 from jsonb_array_elements(a.itens) it
                    where p.hora_inicio is null
                       or abs(extract(epoch from ((it->>'inicio')::time - p.hora_inicio))) <= 5400)
     order by p.id, a.id
  )
  update public.pre_agendamentos p
     set estado = 'lancado', belasis_agendamento_id = achados.ag_id,
         lancado_em = now(), atualizado_em = now()
    from achados
   where p.id = achados.id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

select cron.schedule('belasis-conciliar-pre', '*/5 * * * *', $$select public.belasis_conciliar_pre_agendamentos()$$);

-- "progressiva"/"alisamento" no salão = selagem
create or replace function public.consultar_servicos(p_busca text, p_limite integer default 8)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  with base as (
    select t from regexp_split_to_table(lower(extensions.unaccent(coalesce(p_busca, ''))), '[^a-z0-9]+') t where length(t) >= 3
  ), termos as (
    select t from base
    union
    select s.para from base join (values ('progressiva', 'selagem'), ('alisamento', 'selagem'),
                                         ('alisar', 'selagem'), ('mega', 'alongamento'),
                                         ('aplique', 'alongamento')) s(de, para) on s.de = base.t
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
