-- Respostas do salão ao questionário (docs/16-PERGUNTAS-BASE-CONHECIMENTO.md), 22/11/2026.
-- Regra geral nova: a IA NÃO VENDE cabelo/alongamento. Faz o primeiro atendimento (explica, convida para a
-- avaliação gratuita e agenda); se a cliente pedir foto, preço específico ou quiser fechar → equipe.
--
-- 1. Dias em que o salão não abre (config dias_fechados) entram em salao_aberto → agendar, horários e avisos
-- 2. Avaliação: Karol; quando a agenda dela está fechada (ex.: 12h–13h30, depois das 17h), com a Emilly
-- 3. Avisos por assunto: agenda/horários → Vitória (no expediente) + Emilly; demais assuntos e
--    pré-agendamentos (para confirmar) → Emilly. Erro de sistema e "sem resposta" seguem a regra antiga.
-- 4. Novo motivo de transferência "agenda" (remarcar/cancelar complicado, comanda, lista de espera);
--    gravado como incerteza + "AGENDA:" no resumo (a tabela não aceita motivo novo sem trocar a restrição)
-- 5. Base de conhecimento reescrita com as respostas (itens antigos contraditórios desativados, não apagados)

-- ---------------------------------------------------------------- 1. dias fechados
insert into public.config_bot (chave, valor, descricao) values
  ('dias_fechados', '["2026-12-01", "2026-12-02", "2026-12-08", "2026-12-25"]'::jsonb,
   'Datas (AAAA-MM-DD) em que o salão não abre, além de domingo e segunda')
on conflict (chave) do update set valor = excluded.valor;

create or replace function public.salao_aberto(p_em timestamp with time zone default now())
returns boolean
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_local timestamp := p_em at time zone coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_dia   text := (array['dom','seg','ter','qua','qui','sex','sab'])[extract(dow from v_local)::int + 1];
  v_faixa jsonb := public.cfg('horario_funcionamento') -> v_dia;
begin
  if v_faixa is null or jsonb_typeof(v_faixa) <> 'array' then
    return false;
  end if;
  if jsonb_typeof(public.cfg('dias_fechados')) = 'array'
     and public.cfg('dias_fechados') ? to_char(v_local::date, 'YYYY-MM-DD') then
    return false;
  end if;
  return v_local::time >= (v_faixa->>0)::time and v_local::time < (v_faixa->>1)::time;
end;
$function$;

-- ---------------------------------------------------------------- 2. avaliação com a Emilly como reserva
alter table public.belasis_servico_regras add column if not exists profissional_reserva_id integer;
update public.belasis_servico_regras set profissional_reserva_id = 78182        -- Emilly
 where servico_id in (337494, 587685);                                         -- as duas avaliações

create or replace function public.belasis_aptas(p_servico_id integer)
returns setof integer
language sql
stable
set search_path to ''
as $function$
  with r as (select * from public.belasis_servico_regras where servico_id = p_servico_id)
  select p.id from public.belasis_profissionais p
   where p.ativo and (
     exists (select 1 from r where r.quem = 'unica' and r.profissional_id = p.id)
     or exists (select 1 from r where r.profissional_reserva_id = p.id)
     or exists (select 1 from r join public.belasis_profissional_funcoes f on f.profissional_id = p.id
                 where (r.quem = 'cabeleireiras' and f.funcao = 'cabeleireira') or (r.quem = 'manicures' and f.funcao = 'manicure'))
     or (not exists (select 1 from r) and p.id in (
           select (it->>'profissional_id')::int from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
            where (it->>'servico_id')::int = p_servico_id and a.status not in ('disconfirm', 'removido')
              and a.data >= (now() at time zone 'America/Maceio')::date - 365)
         and not exists (select 1 from public.belasis_profissional_funcoes f
                          where f.profissional_id = p.id and f.funcao in ('recepcao', 'atelie', 'teste'))));
$function$;

-- horários: a reserva entra depois das que fazem o serviço (Karol primeiro, Emilly só se a Karol não puder)
create or replace function public.belasis_quem_faz(p_servico_id integer)
returns table(profissional_id integer, n bigint)
language sql
stable
set search_path to ''
as $function$
  select ap.id, (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                  where (it->>'servico_id')::int = p_servico_id and (it->>'profissional_id')::int = ap.id
                    and a.status not in ('disconfirm', 'removido')
                    and a.data >= (now() at time zone 'America/Maceio')::date - 365)
    from public.belasis_aptas(p_servico_id) ap(id)
   order by (ap.id in (select r.profissional_reserva_id from public.belasis_servico_regras r
                        where r.servico_id = p_servico_id and r.profissional_reserva_id is not null)), 2 desc;
$function$;

-- agendar: serviço de profissional única sem profissional pedida → se a única não pode nesse horário e a
-- reserva pode, marca com a reserva
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  if position('profissional_reserva_id' in d) > 0 then return; end if;
  d := replace(d, $x$  if v_prof is null and v_unica is not null then
    select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_prof from public.belasis_profissionais where id = v_unica and ativo;
  end if;$x$,
  $x$  if v_prof is null and v_unica is not null then
    select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_prof from public.belasis_profissionais
     where ativo and id = coalesce((
       select r.profissional_reserva_id from public.belasis_servico_regras r
        where r.servico_id = v_serv and r.profissional_reserva_id is not null
          and public.belasis_livre_servico(v_serv, v_unica, p_data, p_hora, v_dur) is false
          and public.belasis_livre_servico(v_serv, r.profissional_reserva_id, p_data, p_hora, v_dur) is not false), v_unica);
  end if;$x$);
  if position('profissional_reserva_id' in d) = 0 then raise exception 'agendar_whatsapp: trecho não encontrado'; end if;
  execute d;
end $$;

-- ---------------------------------------------------------------- 3. avisos por assunto
insert into public.config_bot (chave, valor, descricao) values
  ('roteamento_avisos', '{"agenda": ["5579998134284"], "geral": ["5579999216161"]}'::jsonb,
   'Quem recebe cada aviso: agenda/horários (Vitória, no expediente) e demais assuntos + confirmação de pré-agendamento (Emilly). A Emilly também recebe cópia dos avisos de agenda.')
on conflict (chave) do update set valor = excluded.valor;

create or replace function public.rotear_avisos(p_tipo text, p_motivo text, p_em timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_cfg  jsonb := public.cfg('roteamento_avisos');
  v_tels jsonb;
begin
  -- modo teste, erro de sistema e escalonamento "sem resposta" seguem a regra antiga
  if jsonb_typeof(public.cfg('encaminhar_somente_para')) = 'array' and jsonb_array_length(public.cfg('encaminhar_somente_para')) > 0 then return null; end if;
  if jsonb_typeof(v_cfg) <> 'object' or p_tipo in ('erro_sistema', 'sem_resposta_humana') then return null; end if;

  if p_tipo in ('retorno_lembrete', 'cancelamento_cliente', 'pre_agendamento_falhou') or coalesce(p_motivo, '') = 'agenda' then
    v_tels := case when public.salao_aberto(p_em) then coalesce(v_cfg->'agenda', '[]') else '[]'::jsonb end
              || coalesce(v_cfg->'geral', '[]');
  else
    v_tels := coalesce(v_cfg->'geral', '[]');                -- transferências, dúvidas, pré-agendamentos
  end if;

  return public.com_monitoramento((
    select coalesce(jsonb_agg(distinct jsonb_build_object('nome', coalesce(e.nome, 'Equipe'), 'telefone', t.tel)), '[]')
      from jsonb_array_elements_text(v_tels) t(tel) left join public.equipe e on e.telefone = t.tel and e.ativo));
end;
$function$;

do $$
declare d text;
begin
  d := pg_get_functiondef('public.encaminhar_para_responsavel(text,uuid,text,text,text,bigint)'::regprocedure);
  if position('rotear_avisos' in d) > 0 then return; end if;
  d := replace(d, $x$  v_dest := public.destinatarios_encaminhamento(p_tipo);$x$,
                  $x$  v_dest := coalesce(public.rotear_avisos(p_tipo, p_motivo), public.destinatarios_encaminhamento(p_tipo));$x$);
  if position('rotear_avisos' in d) = 0 then raise exception 'encaminhar_para_responsavel: trecho não encontrado'; end if;
  execute d;
end $$;

-- ---------------------------------------------------------------- 4. motivo "agenda"
-- A tabela handoffs só aceita os motivos antigos: "agenda" é gravado como incerteza com o resumo "AGENDA: ...",
-- mas o aviso vai como agenda (Vitória + Emilly).
do $$
declare d text;
begin
  d := pg_get_functiondef('public.iniciar_handoff(uuid,text,text)'::regprocedure);
  if position('AGENDA:' in d) > 0 then return; end if;
  d := replace(d, $x$  if v_motivo = 'negociacao' then$x$,
                  $x$  if v_motivo = 'agenda' then
    v_motivo := 'incerteza';
    v_resumo := 'AGENDA: ' || coalesce(p_resumo, '');
  elsif v_motivo = 'negociacao' then$x$);
  d := replace(d, $x$               p_conversa_id, v_motivo, v_resumo, null, v_handoff_id);$x$,
                  $x$               p_conversa_id, case when p_motivo = 'agenda' then 'agenda' else v_motivo end, v_resumo, null, v_handoff_id);$x$);
  if position('AGENDA:' in d) = 0 or position('then ''agenda'' else v_motivo' in d) = 0 then
    raise exception 'iniciar_handoff: trecho não encontrado';
  end if;
  execute d;
end $$;

-- ---------------------------------------------------------------- 2b. buraco na grade = agenda fechada
-- (ex.: intervalo de almoço da Emilly, 12h–13h30). Antes do 1º horário da grade continua valendo o horário
-- do salão (manhã da Karol).
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
  fuso as (select coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio') tz),
  minutos as (select (pedido.ini + make_interval(mins => m))::time t
                from pedido, generate_series(0, greatest(p_dur, 15) - 1, 5) m)
  select case
    when not public.salao_aberto((p_data + p_ini) at time zone (select tz from fuso)) then false
    when not public.salao_aberto((p_data + ((select fim from pedido) - interval '1 minute')) at time zone (select tz from fuso)) then false
    when not exists (select 1 from h) then null
    when not exists (select 1 from g) then false
    when not exists (select 1 from g where g.lbl = 'available')
         and not exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                          where a.data = p_data and a.status not in ('disconfirm', 'removido')
                            and (it->>'profissional_id')::int = p_pid) then false
    when exists (select 1 from minutos, passo
                  where minutos.t >= (select min(ini) from g) and minutos.t < (select max(ini) from g) + passo.p
                    and not exists (select 1 from g where g.ini <= minutos.t and minutos.t < g.ini + passo.p)) then false
    else not exists (
      select 1 from g, passo, pedido
       where g.lbl <> 'available'
         and g.ini < pedido.fim and g.ini + passo.p > pedido.ini
         and not exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
                          where a.data = p_data and a.status not in ('disconfirm', 'removido')
                            and (it->>'profissional_id')::int = p_pid
                            and (it->>'inicio')::time < (g.ini + passo.p) and (it->>'fim')::time > g.ini)
         and not exists (select 1 from public.pre_agendamentos pa
                          where pa.profissional_id = p_pid and pa.data = p_data and pa.estado <> 'cancelado'
                            and pa.hora_inicio < (g.ini + passo.p)
                            and coalesce(pa.hora_fim, pa.hora_inicio + interval '1 hour') > g.ini))
  end;
$function$;
