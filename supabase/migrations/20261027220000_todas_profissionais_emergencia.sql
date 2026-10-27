-- 27/10 noite (2):
-- 1) o agente enxerga TODAS as profissionais que atendem a categoria do serviço (quem já fez o serviço
--    ou qualquer serviço do mesmo grupo no último ano); regras de prioridade continuam (profissional_prioritaria).
--    consultar_servicos passa a usar a mesma lista. Profissional citada pela cliente é aceita sempre (se livre).
-- 2) nunca 2 clientes no mesmo horário: a checagem também considera os agendamentos feitos pelo WhatsApp
--    que ainda não voltaram na sincronização, e confere agendamentos mesmo em dias sem grade.
-- 3) botão de emergência no painel: painel_definir_agente liga/desliga bot_ativo (entrada e envio já respeitam).

create or replace function public.belasis_quem_faz(p_servico_id integer)
returns table (profissional_id integer, n bigint)
language sql
stable
set search_path to ''
as $function$
  with h as (
    select (it->>'profissional_id')::int pid, (it->>'servico_id')::int sid
      from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
     where a.status not in ('disconfirm', 'removido')
       and a.data >= (now() at time zone 'America/Maceio')::date - 365
  ), grupo as (select group_id from public.belasis_servicos where id = p_servico_id)
  select h.pid, count(*) filter (where h.sid = p_servico_id) * 1000 + count(*)
    from h join public.belasis_servicos s on s.id = h.sid
   where (h.sid = p_servico_id or s.group_id = (select group_id from grupo))
     and h.pid in (select public.belasis_profissionais_que_atendem())
   group by h.pid order by 2 desc;
$function$;

create or replace function public.belasis_profissional_livre(p_pid integer, p_data date, p_ini time, p_dur integer)
returns boolean
language sql
stable
set search_path to ''
as $function$
  with h as (select slots from public.belasis_horarios_livres where profissional_id = p_pid and data = p_data),
  g as (select (s->>'hour')::time ini, s->>'label' lbl from h, jsonb_array_elements(h.slots) s),
  passo as (select coalesce(min(b.ini - a.ini), interval '60 minutes') p from g a join g b on b.ini > a.ini),
  pedido as (select p_ini ini, (p_ini + make_interval(mins => greatest(p_dur, 15)))::time fim),
  conflito as (
    select exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it, pedido
                    where a.data = p_data and a.status not in ('disconfirm', 'removido')
                      and (it->>'profissional_id')::int = p_pid
                      and (it->>'inicio')::time < pedido.fim and (it->>'fim')::time > pedido.ini)
        or exists (select 1 from public.pre_agendamentos pa, pedido
                    where pa.profissional_id = p_pid and pa.data = p_data and pa.estado <> 'cancelado'
                      and pa.hora_inicio < pedido.fim and coalesce(pa.hora_fim, pa.hora_inicio + interval '1 hour') > pedido.ini
                      and (pa.belasis_agendamento_id is null
                           or not exists (select 1 from public.belasis_agendamentos b where b.id = pa.belasis_agendamento_id))) c
  )
  select case
    when (select c from conflito) then false
    when not exists (select 1 from h) then null
    else exists (select 1 from g, pedido where g.ini <= pedido.ini)
         and (select max(g.ini) + passo.p from g, passo group by passo.p) >= (select fim from pedido)
         and not exists (select 1 from g, passo, pedido
                          where g.ini < pedido.fim and g.ini + passo.p > pedido.ini and g.lbl <> 'available')
  end;
$function$;

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
         + (select count(*) from termos where lower(extensions.unaccent(coalesce(g.nome, ''))) like '%' || termos.t || '%') acertos,
           (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
             where (it->>'servico_id')::int = s.id and a.status not in ('disconfirm', 'removido')
               and a.data >= current_date - 120) feitos
      from public.belasis_servicos s
      left join public.belasis_grupos g on g.id = s.group_id
     where s.ativo
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'servico', descricao,
           'categoria', categoria,
           'preco_tabela', case when preco_cents > 0 then 'R$ ' || replace(to_char(preco_cents / 100.0, 'FM999990.00'), '.', ',') end,
           'duracao_min', duracao_min,
           'agendamento_online', online,
           'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) order by q.n desc)
                          from public.belasis_quem_faz(cand.id) q join public.belasis_profissionais p on p.id = q.profissional_id),
           'feitos_ultimos_120_dias', feitos)
         order by acertos desc, feitos desc, descricao), '[]')
    from (select * from cand where acertos > 0
           order by acertos desc, feitos desc, descricao
           limit greatest(1, least(p_limite, 15))) cand;
$function$;

create or replace function public.painel_definir_agente(p_ativo boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  update public.config_bot set valor = to_jsonb(coalesce(p_ativo, false)) where chave = 'bot_ativo';
  return jsonb_build_object('ok', true, 'bot_ativo', coalesce(p_ativo, false));
end;
$function$;

revoke all on function public.painel_definir_agente(boolean) from public, anon;
grant execute on function public.painel_definir_agente(boolean) to authenticated;
