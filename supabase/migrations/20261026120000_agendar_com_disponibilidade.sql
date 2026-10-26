-- Agendamento confirmado na conversa, conferindo a agenda antes.
-- A cliente recebe "agendado"; no Belasis continua entrando como NÃO CONFIRMADO (a equipe valida lá).
--
-- Disponibilidade = grade do Belasis (free_times, a cada 30 min) E nenhum agendamento sincronizado
-- (a cada ~2 min) cruzando o intervalo inteiro do serviço. Sem grade para o dia (muito à frente) → aceita.

-- "9h", "9h30"
create or replace function public.hora_curta(p_hora time)
returns text
language sql
immutable
set search_path to ''
as $function$
  select to_char(p_hora, 'FMHH24') || 'h' || coalesce(nullif(to_char(p_hora, 'MI'), '00'), '');
$function$;

-- profissionais que fazem o serviço, de quem mais faz para quem menos faz
create or replace function public.belasis_quem_faz(p_servico_id integer)
returns table (profissional_id integer, n bigint)
language sql
stable
set search_path to ''
as $function$
  select (it->>'profissional_id')::int, count(*)
    from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
   where (it->>'servico_id')::int = p_servico_id and a.status not in ('disconfirm', 'removido')
     and a.data >= (now() at time zone 'America/Maceio')::date - 120
     and (it->>'profissional_id')::int in (select public.belasis_profissionais_que_atendem())
   group by 1 order by 2 desc;
$function$;

-- true = livre, false = ocupada/fora da grade, null = sem grade para o dia.
-- A grade do Belasis varia por profissional (de 15 em 15 min ou de 1 em 1 h): cada horário da grade cobre
-- [hora, hora + passo). Todo trecho da grade que cruza o atendimento precisa estar "available",
-- o atendimento tem que terminar dentro da grade e não pode cruzar nenhum agendamento sincronizado.
create or replace function public.belasis_profissional_livre(p_pid integer, p_data date, p_ini time, p_dur integer)
returns boolean
language sql
stable
set search_path to ''
as $function$
  with h as (select slots from public.belasis_horarios_livres where profissional_id = p_pid and data = p_data),
  g as (select (s->>'hour')::time ini, s->>'label' lbl from h, jsonb_array_elements(h.slots) s),
  passo as (select coalesce(min(b.ini - a.ini), interval '60 minutes') p from g a join g b on b.ini > a.ini),
  pedido as (select p_ini ini, (p_ini + make_interval(mins => greatest(p_dur, 15)))::time fim)
  select case
    when not exists (select 1 from h) then null
    else exists (select 1 from g, pedido where g.ini <= pedido.ini)
         and (select max(g.ini) + passo.p from g, passo group by passo.p) >= (select fim from pedido)
         and not exists (select 1 from g, passo, pedido
                          where g.ini < pedido.fim and g.ini + passo.p > pedido.ini and g.lbl <> 'available')
         and not exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it, pedido
                          where a.data = p_data and a.status not in ('disconfirm', 'removido')
                            and (it->>'profissional_id')::int = p_pid
                            and (it->>'inicio')::time < pedido.fim and (it->>'fim')::time > pedido.ini)
  end;
$function$;

-- horários livres de um dia para um serviço (com ou sem profissional), de 30 em 30 min
create or replace function public.belasis_horarios_disponiveis(p_servico text, p_data date, p_profissional text default null, p_limite integer default 6)
returns jsonb
language plpgsql
stable
set search_path to ''
as $function$
declare
  v_serv integer := public.belasis_resolver_servico(p_servico);
  v_dur  integer;
  v_pid  integer;
  v_res  jsonb := '[]';
  t      time;
  r      record;
  v_fuso text := coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
begin
  if v_serv is null then return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado'); end if;
  select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;
  if not public.salao_aberto((p_data + time '12:00') at time zone v_fuso) then
    return jsonb_build_object('ok', false, 'erro', 'salao_fechado', 'orientacao', 'O salão abre de terça a sábado.');
  end if;
  if nullif(btrim(coalesce(p_profissional, '')), '') is not null then
    v_pid := public.belasis_resolver_profissional(p_profissional);
    if v_pid is null then return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrada'); end if;
  end if;

  t := time '09:00';
  while t <= time '18:00' and jsonb_array_length(v_res) < p_limite loop
    if (p_data + t) at time zone v_fuso > now() + interval '1 hour' then
      for r in select q.profissional_id pid from public.belasis_quem_faz(v_serv) q
                where v_pid is null or q.profissional_id = v_pid
               union all select v_pid where v_pid is not null and not exists (select 1 from public.belasis_quem_faz(v_serv) q where q.profissional_id = v_pid) loop
        if public.belasis_profissional_livre(r.pid, p_data, t, v_dur) then
          v_res := v_res || jsonb_build_object('hora', public.hora_curta(t),
                     'profissional', (select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = r.pid));
          exit;
        end if;
      end loop;
    end if;
    t := t + interval '30 minutes';
  end loop;
  return jsonb_build_object('ok', true, 'data', public.data_curta_pt(p_data),
    'servico', (select descricao from public.belasis_servicos where id = v_serv), 'duracao_min', v_dur,
    'horarios', v_res);
end;
$function$;

-- agenda na conversa: confere, escolhe profissional se não houver preferência e registra
create or replace function public.agendar_whatsapp(p_conversa_id uuid, p_servico text, p_data date, p_hora time,
                                                   p_profissional text default null, p_confirmacao text default null, p_observacao text default null)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_fuso  text := coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_quando timestamptz := (p_data + p_hora) at time zone v_fuso;
  v_serv  integer := public.belasis_resolver_servico(p_servico);
  v_dur   integer;
  v_pid   integer;
  v_livre boolean;
  v_nome  text;
  v_res   jsonb;
  r       record;
begin
  if v_quando < now() then
    return jsonb_build_object('ok', false, 'erro', 'data_no_passado', 'orientacao', 'Esse horário já passou. Pergunte outro.');
  end if;
  if not public.salao_aberto(v_quando) then
    return jsonb_build_object('ok', false, 'erro', 'fora_do_horario',
      'orientacao', 'O salão funciona de terça a sábado, das 9h às 18h. Peça outro dia/horário.');
  end if;
  if v_serv is null then
    return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado',
      'orientacao', 'Não achei esse serviço no catálogo. Use consultar_servicos e confirme com a cliente qual é.');
  end if;
  select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;

  if nullif(btrim(coalesce(p_profissional, '')), '') is not null then
    v_pid := public.belasis_resolver_profissional(p_profissional);
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrada',
        'orientacao', 'Não achei essa profissional. Pergunte de novo o nome ou ofereça quem faz o serviço.',
        'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))
                       from (select profissional_id from public.belasis_quem_faz(v_serv) limit 4) q
                       join public.belasis_profissionais p on p.id = q.profissional_id));
    end if;
    v_livre := public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur);
    if v_livre = false then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Esse horário não está livre com essa profissional. Ofereça 2 ou 3 opções abaixo, sem listar tudo.',
        'livres_com_ela', public.belasis_horarios_disponiveis(p_servico, p_data, p_profissional, 4) -> 'horarios',
        'outras_no_mesmo_horario', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))
                                      from public.belasis_quem_faz(v_serv) q join public.belasis_profissionais p on p.id = q.profissional_id
                                     where q.profissional_id <> v_pid and public.belasis_profissional_livre(q.profissional_id, p_data, p_hora, v_dur)));
    end if;
  else
    if not exists (select 1 from public.belasis_quem_faz(v_serv)) then
      return jsonb_build_object('ok', false, 'erro', 'sem_profissional',
        'orientacao', 'Pergunte se ela tem preferência de profissional; se não souber, transfira (motivo incerteza).');
    end if;
    for r in select profissional_id from public.belasis_quem_faz(v_serv) loop
      v_livre := public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur);
      if v_livre is distinct from false then v_pid := r.profissional_id; exit; end if;
    end loop;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Ninguém livre nesse horário. Ofereça 2 ou 3 opções abaixo, sem listar tudo.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 4) -> 'horarios');
    end if;
  end if;

  select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_nome from public.belasis_profissionais where id = v_pid;
  v_res := public.criar_pre_agendamento(p_conversa_id, p_servico, p_data, p_hora, v_nome, v_serv, v_pid,
                                        (p_hora + make_interval(mins => v_dur))::time, p_confirmacao, p_observacao);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;
  return jsonb_build_object('ok', true, 'agendado', true,
    'servico', (select descricao from public.belasis_servicos where id = v_serv),
    'profissional', v_nome, 'dia', public.data_curta_pt(p_data), 'hora', public.hora_curta(p_hora),
    'grade_conferida', v_livre is not null,
    'orientacao', 'Diga à cliente que está agendado (dia, hora e profissional), curto e natural.');
end;
$function$;

-- WhatsApp mais ágil: agrupa por 4 s (era 8) e intervalo mínimo entre mensagens de 1,5 s (era 3)
update public.config_bot set valor = '4'::jsonb where chave = 'janela_agrupamento_segundos';
update public.config_bot set valor = '1500'::jsonb where chave = 'envio_intervalo_min_ms';

-- n8n (CBK · Agente Core, 26/10): ferramenta "agendar" chama agendar_whatsapp; nova "consultar_horarios"
-- chama belasis_horarios_disponiveis; modelo gpt-5-mini com raciocínio "minimal"; "digitando" de 1,2 a 3,5 s.
