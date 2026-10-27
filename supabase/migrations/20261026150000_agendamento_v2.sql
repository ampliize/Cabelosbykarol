-- Agendamento v2 (correções do teste do cliente em 26/10):
--  1. agendar só aceita horário que apareceu na conversa (cliente disse ou escolheu de uma oferta)
--  2. agendar exige profissional ou "sem preferência" explícito (o agente precisa perguntar)
--  3. cliente sem cadastro no Belasis: pedir nome completo (e nascimento) e cadastrar
--  4. agendamento entra CONFIRMADO no Belasis (dispara as mensagens automáticas do Belasis)
--  5. remarcar = cria o novo e cancela o anterior da própria cliente; cancelar pelo WhatsApp
--  6. venda casada: serviços que as clientes mais fazem juntos (histórico real)
--  7. horários: lista do dia inteiro + se o horário pedido está livre (o agente não deduz mais)

alter table public.conversas add column if not exists nascimento date;
alter table public.belasis_fila add column if not exists meta jsonb;

-- assinaturas novas (mais parâmetros): remove as antigas para não haver ambiguidade
drop function if exists public.agendar_whatsapp(uuid, text, date, time, text, text, text);
drop function if exists public.belasis_horarios_disponiveis(text, date, text, integer);

insert into public.config_bot (chave, valor, descricao) values
  ('belasis_status_agendamento', '"confirmed"'::jsonb, 'Status com que o agendamento do WhatsApp entra no Belasis (confirmed dispara as mensagens automáticas do Belasis)')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

alter table public.notificacoes_equipe drop constraint if exists notificacoes_equipe_tipo_check;
alter table public.notificacoes_equipe add constraint notificacoes_equipe_tipo_check check (tipo in (
  'transferencia', 'duvida_agente', 'problema_atendimento', 'erro_sistema', 'sem_resposta_humana',
  'pre_agendamento', 'retorno_lembrete', 'pre_agendamento_lancado', 'pre_agendamento_falhou', 'cancelamento_cliente'));

-- ids do Belasis da cliente desta conversa (pelo telefone)
create or replace function public.belasis_clientes_da_conversa(p_conversa_id uuid)
returns setof integer
language sql
stable
set search_path to ''
as $function$
  select bc.id from public.belasis_clientes bc, public.conversas c
   where c.id = p_conversa_id and bc.telefones && public.variantes_telefone(c.telefone);
$function$;

-- próximo agendamento ativo da cliente (opcionalmente numa data)
create or replace function public.belasis_proximo_agendamento(p_conversa_id uuid, p_data date default null)
returns table (id integer, data date, inicio text, servico text, profissional text)
language sql
stable
set search_path to ''
as $function$
  select a.id, a.data, a.itens->0->>'inicio',
         (select descricao from public.belasis_servicos where id = (a.itens->0->>'servico_id')::int),
         (select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = (a.itens->0->>'profissional_id')::int)
    from public.belasis_agendamentos a
   where a.cliente_id in (select public.belasis_clientes_da_conversa(p_conversa_id))
     and a.status not in ('disconfirm', 'removido')
     and a.data >= (now() at time zone 'America/Maceio')::date
     and (p_data is null or a.data = p_data)
  union
  select p.belasis_agendamento_id, p.data, to_char(p.hora_inicio, 'HH24:MI'),
         (select descricao from public.belasis_servicos where id = p.servico_id), p.profissional
    from public.pre_agendamentos p
   where p.conversa_id = p_conversa_id and p.estado = 'lancado' and p.belasis_agendamento_id is not null
     and p.data >= (now() at time zone 'America/Maceio')::date and (p_data is null or p.data = p_data)
     and not exists (select 1 from public.belasis_agendamentos a where a.id = p.belasis_agendamento_id)
  order by 2, 3 limit 1;
$function$;

-- a hora apareceu na conversa recente? ("15h", "às 15", "15:00", "3 da tarde", oferta do agente aceita)
create or replace function public.hora_mencionada(p_conversa_id uuid, p_hora time)
returns boolean
language plpgsql
stable
set search_path to ''
as $function$
declare
  h int := extract(hour from p_hora);
  m int := extract(minute from p_hora);
  hh text := '0?' || h::text;
  re text;
begin
  re := '(\m(as|às|pras|pra|para as|umas|depois das|antes das|a partir das|lá pelas)\s+' || hh || '\M)'
     || '|(\m' || hh || '\s*(h|hs|hrs?|horas?)(' || lpad(m::text, 2, '0') || ')?\M)'
     || '|(\m' || hh || ':' || lpad(m::text, 2, '0') || '\M)';
  if h between 13 and 18 then
    re := re || '|(\m' || (h - 12)::text || '\s*(h|hs|horas?)?\s*(da|de)\s+tarde\M)';
  end if;
  if h between 9 and 11 then
    re := re || '|(\m' || h::text || '\s*(h|hs|horas?)?\s*(da|de)\s+manh)';
  end if;
  return exists (select 1 from public.mensagens
                  where conversa_id = p_conversa_id and autor in ('cliente', 'bot')
                    and criado_em > now() - interval '3 hours' and texto ~* re);
end;
$function$;

-- venda casada: o que as clientes mais fazem junto com o serviço (sem química/alongamento/avaliação)
create or replace function public.belasis_complementos(p_servico_id integer, p_limite integer default 2)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  with g as (select a.id, (it->>'servico_id')::int sid from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
              where a.data >= current_date - 180 and a.status not in ('disconfirm', 'removido'))
  select coalesce(jsonb_agg(jsonb_build_object('servico', descricao, 'preco', 'R$ ' || (preco_cents / 100), 'duracao_min', duracao_min) order by n desc), '[]')
    from (select s.descricao, s.preco_cents, s.duracao_min, count(*) n
            from g g1 join g g2 on g1.id = g2.id and g2.sid <> g1.sid
            join public.belasis_servicos s on s.id = g2.sid and s.ativo and s.preco_cents > 0
            left join public.belasis_grupos gr on gr.id = s.group_id
           where g1.sid = p_servico_id and coalesce(gr.nome, '') !~* 'químic|quimic|alongamento|avalia|ateli|produ'
             and s.descricao !~* 'retirada|remo[cç]|selagem|colora|luzes|mecha|alongamento|\+'
           group by s.id, s.descricao, s.preco_cents, s.duracao_min having count(*) >= 3
           order by count(*) desc limit p_limite) x;
$function$;

-- horários livres do dia inteiro (de 30 em 30 min) + se o horário pedido está livre
create or replace function public.belasis_horarios_disponiveis(p_servico text, p_data date, p_profissional text default null, p_limite integer default 30, p_hora time default null)
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
  v_ped  jsonb;
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

  if p_hora is not null then
    v_ped := jsonb_build_object('hora', public.hora_curta(p_hora),
      'livre', exists (select 1 from jsonb_array_elements(v_res) x where x->>'hora' = public.hora_curta(p_hora))
               or (v_pid is not null and coalesce(public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur), true)));
  end if;

  return jsonb_build_object('ok', true, 'data', public.data_curta_pt(p_data),
    'servico', (select descricao from public.belasis_servicos where id = v_serv), 'duracao_min', v_dur,
    'horario_pedido', v_ped, 'horarios_livres', v_res,
    'observacao', 'Lista completa do dia. Horário fora da lista = ocupado. Ofereça só 2 ou 3.');
end;
$function$;

-- cancela (PATCH) um agendamento da própria cliente — usado em remarcação e cancelamento
create or replace function public.belasis_enfileirar_cancelamento(p_ag_id integer, p_conversa_id uuid, p_motivo text)
returns void
language plpgsql
set search_path to ''
as $function$
begin
  -- só agendamento da cliente desta conversa ou criado por nós para ela
  if not exists (select 1 from public.belasis_agendamentos a where a.id = p_ag_id
                   and a.cliente_id in (select public.belasis_clientes_da_conversa(p_conversa_id)))
     and not exists (select 1 from public.pre_agendamentos p where p.belasis_agendamento_id = p_ag_id and p.conversa_id = p_conversa_id) then
    raise exception 'agendamento % não pertence a esta cliente', p_ag_id;
  end if;
  insert into public.belasis_fila (chave, caminho, metodo, corpo, meta)
  values ('escrita_cancelar:' || p_ag_id, '/schedule_groups/' || p_ag_id || '/cancel', 'PATCH', '{}'::jsonb,
          jsonb_build_object('conversa_id', p_conversa_id, 'motivo', p_motivo))
  on conflict (chave) do nothing;
  update public.pre_agendamentos set estado = 'cancelado', atualizado_em = now()
   where belasis_agendamento_id = p_ag_id;
end;
$function$;

create or replace function public.agendar_whatsapp(
  p_conversa_id uuid, p_servico text, p_data date, p_hora time,
  p_profissional text default null, p_confirmacao text default null, p_observacao text default null,
  p_sem_preferencia boolean default false, p_nome_completo text default null, p_nascimento date default null,
  p_remarcar boolean default false, p_complemento boolean default false)
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
  v_ant_id integer;
  v_ant_data date;
  v_ant_ini text;
  r       record;
  v_prof  text := nullif(btrim(coalesce(p_profissional, '')), '');
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

  -- trava 1: horário escolhido pela cliente (complemento encaixa logo depois, então dispensa)
  if not p_complemento and not public.hora_mencionada(p_conversa_id, p_hora) then
    return jsonb_build_object('ok', false, 'erro', 'hora_nao_informada',
      'orientacao', 'A cliente ainda não escolheu o horário. Pergunte que horário ela prefere (pode usar consultar_horarios e sugerir 2 ou 3). Não escolha por ela.');
  end if;

  -- complemento sem profissional: tenta a mesma do agendamento que acabou de ser feito
  if p_complemento and v_prof is null then
    select profissional into v_prof from public.pre_agendamentos
     where conversa_id = p_conversa_id and criado_em > now() - interval '2 hours' order by id desc limit 1;
  end if;

  -- trava 2: profissional perguntada
  if v_prof is null and not p_sem_preferencia and not p_complemento then
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',
      'orientacao', 'Pergunte se ela tem preferência de profissional antes de agendar. Pode sugerir quem mais faz o serviço.',
      'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))
                     from (select profissional_id from public.belasis_quem_faz(v_serv) limit 3) q
                     join public.belasis_profissionais p on p.id = q.profissional_id));
  end if;

  -- trava 3: cadastro no Belasis (para receber as mensagens de confirmação/alteração/cancelamento)
  if not exists (select 1 from public.belasis_clientes_da_conversa(p_conversa_id)) then
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is null
       and coalesce((select btrim(nome) from public.conversas where id = p_conversa_id), '') !~ '\S+\s+\S+' then
      return jsonb_build_object('ok', false, 'erro', 'precisa_cadastro',
        'orientacao', 'Ela ainda não tem cadastro no salão. Pergunte, numa mensagem só e com leveza, o nome completo e a data de nascimento (pra fazer o cadastro e ela receber a confirmação). Se ela disser que já é cliente, peça o nome completo do cadastro.');
    end if;
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is not null then
      update public.conversas set nome = initcap(btrim(p_nome_completo)), nascimento = coalesce(p_nascimento, nascimento)
       where id = p_conversa_id;
    end if;
  end if;

  if v_prof is not null then
    v_pid := public.belasis_resolver_profissional(v_prof);
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrada',
        'orientacao', 'Não achei essa profissional. Pergunte de novo o nome ou ofereça quem faz o serviço.',
        'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))
                       from (select profissional_id from public.belasis_quem_faz(v_serv) limit 4) q
                       join public.belasis_profissionais p on p.id = q.profissional_id));
    end if;
    v_livre := public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur);
    if v_livre = false and not p_complemento then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Esse horário não está livre com essa profissional. Ofereça 2 ou 3 opções abaixo, sem listar tudo.',
        'livres_com_ela', public.belasis_horarios_disponiveis(p_servico, p_data, v_prof, 6) -> 'horarios_livres',
        'outras_no_mesmo_horario', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))
                                      from public.belasis_quem_faz(v_serv) q join public.belasis_profissionais p on p.id = q.profissional_id
                                     where q.profissional_id <> v_pid and public.belasis_profissional_livre(q.profissional_id, p_data, p_hora, v_dur)));
    end if;
    if v_livre = false and p_complemento then v_pid := null; end if;  -- complemento: tenta outra profissional
  end if;

  if v_pid is null then
    for r in select profissional_id from public.belasis_quem_faz(v_serv) loop
      v_livre := public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur);
      if v_livre is distinct from false then v_pid := r.profissional_id; exit; end if;
    end loop;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', case when exists (select 1 from public.belasis_quem_faz(v_serv)) then 'horario_ocupado' else 'sem_profissional' end,
        'orientacao', 'Ninguém livre nesse horário para esse serviço. Ofereça 2 ou 3 opções abaixo, sem listar tudo.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 6) -> 'horarios_livres');
    end if;
  end if;

  -- remarcação: guarda o agendamento anterior para cancelar depois de criar o novo
  if p_remarcar then
    select x.id, x.data, x.inicio into v_ant_id, v_ant_data, v_ant_ini from public.belasis_proximo_agendamento(p_conversa_id) x;
  end if;

  select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_nome from public.belasis_profissionais where id = v_pid;
  v_res := public.criar_pre_agendamento(p_conversa_id, p_servico, p_data, p_hora, v_nome, v_serv, v_pid,
                                        (p_hora + make_interval(mins => v_dur))::time, p_confirmacao, p_observacao);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;

  if v_ant_id is not null then
    perform public.belasis_enfileirar_cancelamento(v_ant_id, p_conversa_id, 'remarcação pelo WhatsApp');
  end if;

  return jsonb_build_object('ok', true, 'agendado', true,
    'servico', (select descricao from public.belasis_servicos where id = v_serv),
    'profissional', v_nome, 'dia', public.data_curta_pt(p_data), 'hora', public.hora_curta(p_hora),
    'termina', public.hora_curta((p_hora + make_interval(mins => v_dur))::time),
    'remarcado_de', case when v_ant_id is not null then public.data_curta_pt(v_ant_data) || ' às ' || public.hora_curta(v_ant_ini::time) end,
    'sugestao_complemento', case when p_complemento then '[]'::jsonb else public.belasis_complementos(v_serv) end,
    'orientacao', 'Diga que está agendado (dia, hora e profissional), curto e natural. Se houver sugestao_complemento, ofereça UMA delas em seguida, leve, com o preço (sem insistir).');
end;
$function$;

create or replace function public.cancelar_agendamento_whatsapp(p_conversa_id uuid, p_data date default null)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v record;
begin
  select * into v from public.belasis_proximo_agendamento(p_conversa_id, p_data);
  if v.id is null then
    return jsonb_build_object('ok', false, 'erro', 'sem_agendamento',
      'orientacao', 'Não achei agendamento futuro dela. Pergunte o dia ou transfira (motivo incerteza).');
  end if;
  perform public.belasis_enfileirar_cancelamento(v.id, p_conversa_id, 'cancelado pela cliente no WhatsApp');
  perform public.belasis_disparar_sync();
  return jsonb_build_object('ok', true, 'cancelado', true, 'dia', public.data_curta_pt(v.data),
    'hora', public.hora_curta(v.inicio::time), 'servico', v.servico, 'profissional', v.profissional,
    'orientacao', 'Confirme que cancelou, com carinho, e pergunte se quer remarcar.');
end;
$function$;

-- escrita: status configurável (confirmed) e cadastro com nascimento
do $$
declare d text;
begin
  d := pg_get_functiondef('public.belasis_enfileirar_agendamento(bigint,integer)'::regprocedure);
  d := replace(d, $x$'status', 'unconfirmed',$x$, $x$'status', coalesce(public.cfg('belasis_status_agendamento') #>> '{}', 'unconfirmed'),$x$);
  d := replace(d, $x$'Pré-agendamento pelo WhatsApp (assistente IA) - conferir e confirmar com a cliente.'$x$,
                  $x$'Pré-agendamento pelo WhatsApp (assistente IA).'$x$);
  if position('belasis_status_agendamento' in d) = 0 then raise exception 'enfileirar_agendamento: trecho não encontrado'; end if;
  execute d;

  d := pg_get_functiondef('public.belasis_preparar_escrita(bigint)'::regprocedure);
  d := replace(d, $x$'phone', c.telefone, 'cellphone', c.telefone,
                               'observation', 'Cadastrada pelo assistente WhatsApp'),$x$,
                  $x$'phone', c.telefone, 'cellphone', c.telefone,
                               'observation', 'Cadastrada pelo assistente WhatsApp')
                    || case when c.nascimento is not null then jsonb_build_object('birthday', c.nascimento) else '{}'::jsonb end,$x$);
  if position('birthday' in d) = 0 then raise exception 'preparar_escrita: trecho não encontrado'; end if;
  execute d;

  -- registrar_escrita: resultado do cancelamento
  d := pg_get_functiondef('public.belasis_registrar_escrita(public.belasis_fila,integer,jsonb,text)'::regprocedure);
  if position('escrita_cancelar' in d) = 0 then
    d := replace(d, $x$  select * into p from public.pre_agendamentos where id = f.pre_agendamento_id;$x$,
$x$  if v_tipo = 'escrita_cancelar' then
    if p_status between 200 and 299 then
      update public.belasis_agendamentos set status = 'disconfirm', atualizado_em = now()
       where id = split_part(split_part(f.chave, ':', 2), '#', 1)::int;
    end if;
    perform public.encaminhar_seguro('cancelamento_cliente', nullif(f.meta->>'conversa_id', '')::uuid,
      case when p_status between 200 and 299 then 'Cancelado no Belasis (' || coalesce(f.meta->>'motivo', 'WhatsApp') || ')'
           else 'NÃO consegui cancelar no Belasis: cancele manualmente' end,
      'Agendamento ' || split_part(f.chave, ':', 2) || coalesce(' · ' || p_erro, ''), null);
    return;
  end if;
  select * into p from public.pre_agendamentos where id = f.pre_agendamento_id;$x$);
    if position('escrita_cancelar' in d) = 0 then raise exception 'registrar_escrita: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;
