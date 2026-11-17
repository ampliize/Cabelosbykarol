-- Regra do salão (Emilly, 17/11): a AVALIAÇÃO é o único serviço que pode ser marcado mesmo com a agenda
-- cheia ("a Karol consegue fazer a avaliação rapidinho"); só não pode quando a agenda dela está FECHADA.
-- Avaliação somente com a Karol (já está em belasis_servico_regras como 'unica').
-- Caso real: Renata pediu avaliação de manhã, o agente disse que não havia vaga e marcou à tarde.
--
-- * belasis_servico_regras.encaixe_agenda_cheia: liga a exceção por serviço (as duas avaliações)
-- * belasis_agenda_aberta: aceita por cima de atendimentos; recusa só agenda fechada:
--     - salão fechado no dia/horário (terça a sábado, 9h às 18h);
--     - profissional sem grade no dia (folga) → false;
--     - faixa "indisponível" no Belasis SEM nenhum atendimento dela ali (bloqueio, almoço) → false.
--   Antes do 1º horário da grade (a grade da Karol começa às 11h nos dias de semana, mas a equipe atende
--   avaliação de manhã) vale o horário do salão.
-- * belasis_livre_servico: usa a regra acima para serviços de encaixe e a regra normal para os demais;
--   agendar, consultar horários e "quem está livre" passam a chamar essa função.

alter table public.belasis_servico_regras add column if not exists encaixe_agenda_cheia boolean not null default false;
update public.belasis_servico_regras set encaixe_agenda_cheia = true where servico_id in (337494, 587685);

create or replace function public.belasis_agenda_aberta(p_pid integer, p_data date, p_ini time, p_dur integer)
returns boolean
language sql
stable
set search_path to ''
as $function$
  with h as (select slots from public.belasis_horarios_livres where profissional_id = p_pid and data = p_data),
  g as (select (s->>'hour')::time ini, s->>'label' lbl from h, jsonb_array_elements(h.slots) s),
  passo as (select coalesce(min(b.ini - a.ini), interval '60 minutes') p from g a join g b on b.ini > a.ini),
  pedido as (select p_ini ini, (p_ini + make_interval(mins => greatest(p_dur, 15)))::time fim),
  fuso as (select coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio') tz)
  select case
    when not public.salao_aberto((p_data + p_ini) at time zone (select tz from fuso)) then false
    when not public.salao_aberto((p_data + ((select fim from pedido) - interval '1 minute')) at time zone (select tz from fuso)) then false
    when not exists (select 1 from h) then null                            -- grade ainda não sincronizada
    when not exists (select 1 from g) then false                           -- sem grade no dia: folga
    when not exists (select 1 from g where g.lbl = 'available')
         and not exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                          where a.data = p_data and a.status not in ('disconfirm', 'removido')
                            and (it->>'profissional_id')::int = p_pid) then false   -- dia todo fechado
    else not exists (
      select 1 from g, passo, pedido
       where g.lbl <> 'available'
         and g.ini < pedido.fim and g.ini + passo.p > pedido.ini            -- faixa indisponível no pedido...
         and not exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                          where a.data = p_data and a.status not in ('disconfirm', 'removido')
                            and (it->>'profissional_id')::int = p_pid
                            and (it->>'inicio')::time < (g.ini + passo.p) and (it->>'fim')::time > g.ini)
         and not exists (select 1 from public.pre_agendamentos pa
                          where pa.profissional_id = p_pid and pa.data = p_data and pa.estado <> 'cancelado'
                            and pa.hora_inicio < (g.ini + passo.p)
                            and coalesce(pa.hora_fim, pa.hora_inicio + interval '1 hour') > g.ini))  -- ...sem atendimento = fechada
  end;
$function$;

create or replace function public.belasis_livre_servico(p_serv integer, p_pid integer, p_data date, p_ini time, p_dur integer)
returns boolean
language sql
stable
set search_path to ''
as $function$
  select case when exists (select 1 from public.belasis_servico_regras r where r.servico_id = p_serv and r.encaixe_agenda_cheia)
              then public.belasis_agenda_aberta(p_pid, p_data, p_ini, p_dur)
              else public.belasis_profissional_livre(p_pid, p_data, p_ini, p_dur) end;
$function$;

do $$
declare d text;
begin
  -- agendar_whatsapp
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  if position('belasis_livre_servico' in d) = 0 then
    d := replace(d, 'public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur)', 'public.belasis_livre_servico(v_serv, v_pid, p_data, p_hora, v_dur)');
    d := replace(d, 'public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur)', 'public.belasis_livre_servico(v_serv, r.profissional_id, p_data, p_hora, v_dur)');
    if position('belasis_profissional_livre' in d) > 0 or position('belasis_livre_servico' in d) = 0 then
      raise exception 'agendar_whatsapp: trecho não encontrado';
    end if;
    execute d;
  end if;

  -- belasis_horarios_disponiveis
  d := pg_get_functiondef('public.belasis_horarios_disponiveis(text,date,text,integer,time)'::regprocedure);
  if position('belasis_livre_servico' in d) = 0 then
    d := replace(d, 'public.belasis_profissional_livre(r.pid, p_data, t, v_dur)', 'public.belasis_livre_servico(v_serv, r.pid, p_data, t, v_dur)');
    d := replace(d, 'public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur)', 'public.belasis_livre_servico(v_serv, v_pid, p_data, p_hora, v_dur)');
    if position('belasis_profissional_livre' in d) > 0 then raise exception 'belasis_horarios_disponiveis: trecho não encontrado'; end if;
    execute d;
  end if;

  -- belasis_livres_no_horario
  d := pg_get_functiondef('public.belasis_livres_no_horario(integer,date,time)'::regprocedure);
  if position('belasis_livre_servico' in d) = 0 then
    d := replace(d, 'public.belasis_profissional_livre(l.profissional_id, p_data, p_hora, coalesce(s.duracao_min, 60))',
                    'public.belasis_livre_servico(p_servico_id, l.profissional_id, p_data, p_hora, coalesce(s.duracao_min, 60))');
    if position('belasis_profissional_livre' in d) > 0 then raise exception 'belasis_livres_no_horario: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;
