-- Comanda única (29/10): todos os serviços da mesma cliente no mesmo dia vão para UM schedule_group
-- no Belasis (como a recepção faz), em vez de uma comanda por serviço — a cliente recebe uma confirmação só.
--
-- Como funciona: o pré-agendamento fica "aguardando_comanda" (já bloqueia o horário na checagem de vaga).
-- Um cron junta os serviços da conversa/dia e lança tudo junto quando a conversa sossega:
-- último serviço há >= comanda_espera_minutos E cliente sem mensagem há 3 min (ou, no máximo, 20 min).

alter table public.pre_agendamentos add column if not exists comanda_id bigint;

insert into public.config_bot (chave, valor, descricao) values
  ('comanda_espera_minutos', '5'::jsonb, 'Minutos esperando a cliente adicionar outros serviços antes de lançar a comanda única no Belasis')
on conflict (chave) do nothing;

-- o trigger só marca; quem lança é belasis_processar_comandas
create or replace function public.tg_pre_agendamento_escrita()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if coalesce((public.cfg('belasis_escrita_automatica'))::boolean, false) then
    update public.pre_agendamentos set escrita_estado = 'aguardando_comanda', atualizado_em = now() where id = new.id;
  end if;
  return null;
end;
$function$;

create or replace function public.belasis_processar_comandas()
returns integer
language plpgsql
set search_path to ''
as $function$
declare
  g      record;
  v_n    integer := 0;
  v_esp  integer := coalesce((public.cfg('comanda_espera_minutos'))::int, 5);
begin
  for g in
    select p.conversa_id, p.data, min(p.id) lider
      from public.pre_agendamentos p
      join public.conversas c on c.id = p.conversa_id
     where p.escrita_estado = 'aguardando_comanda' and p.estado <> 'cancelado'
     group by p.conversa_id, p.data, c.ultima_msg_cliente_em
    having max(p.criado_em) < now() - make_interval(mins => v_esp)
       and (coalesce(c.ultima_msg_cliente_em, '-infinity') < now() - interval '3 minutes'
            or max(p.criado_em) < now() - interval '20 minutes')
  loop
    update public.pre_agendamentos set comanda_id = g.lider, atualizado_em = now()
     where conversa_id = g.conversa_id and data = g.data
       and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado';
    begin
      perform public.belasis_preparar_escrita(g.lider);
    exception when others then
      perform public.belasis_escrita_falhou(g.lider, 'erro interno: ' || sqlerrm);
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

-- resolve serviço/profissional de cada item da comanda e enfileira cliente ou agendamento
create or replace function public.belasis_preparar_escrita(p_pre_id bigint)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  p        public.pre_agendamentos;
  c        public.conversas;
  m        public.pre_agendamentos;
  v_serv   integer;
  v_prof   integer;
  v_dur    integer;
  v_cli    integer;
  v_teste  integer := nullif(public.cfg('belasis_escrita_profissional_teste') #>> '{}', '')::int;
begin
  select * into p from public.pre_agendamentos where id = p_pre_id;
  if p.id is null then return jsonb_build_object('ok', false, 'erro', 'pre_agendamento_inexistente'); end if;
  select * into c from public.conversas where id = p.conversa_id;
  if p.comanda_id is null then
    update public.pre_agendamentos set comanda_id = p.id where id = p.id;
  end if;

  for m in select * from public.pre_agendamentos where comanda_id = p_pre_id and estado <> 'cancelado' order by id loop
    v_serv := coalesce(m.servico_id, public.belasis_resolver_servico(m.servico));
    if v_serv is null then
      perform public.belasis_escrita_falhou(p_pre_id, 'serviço "' || coalesce(m.servico, '?') || '" não encontrado no catálogo');
      return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado');
    end if;
    select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;
    v_prof := coalesce(v_teste, m.profissional_id, public.belasis_resolver_profissional(m.profissional),
                       public.belasis_escolher_profissional(v_serv, m.data, m.hora_inicio));
    if v_prof is null then
      perform public.belasis_escrita_falhou(p_pre_id, 'não achei profissional para ' || coalesce(m.servico, 'o serviço'));
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrado');
    end if;
    update public.pre_agendamentos
       set servico_id = v_serv, profissional_id = v_prof,
           hora_fim = coalesce(hora_fim, hora_inicio + make_interval(mins => greatest(v_dur, 15))),
           escrita_estado = 'na_fila', atualizado_em = now()
     where id = m.id;
  end loop;

  select bc.id into v_cli from public.belasis_clientes bc
   where bc.telefones && public.variantes_telefone(c.telefone) order by bc.ativo desc, bc.id desc limit 1;

  if v_cli is not null then
    perform public.belasis_enfileirar_agendamento(p_pre_id, v_cli);
  else
    insert into public.belasis_fila (chave, caminho, metodo, corpo, pre_agendamento_id)
    values ('escrita_cliente:' || p_pre_id, '/clients', 'POST',
            jsonb_build_object('name', coalesce(nullif(btrim(c.nome), ''), nullif(btrim(c.push_name), ''), 'Cliente WhatsApp'),
                               'phone', c.telefone, 'cellphone', c.telefone,
                               'observation', 'Cadastrada pelo assistente WhatsApp')
                    || case when c.nascimento is not null then jsonb_build_object('birthday', c.nascimento) else '{}'::jsonb end,
            p_pre_id)
    on conflict (chave) do nothing;
  end if;

  perform public.belasis_disparar_sync();
  return jsonb_build_object('ok', true, 'cliente_id', v_cli);
end;
$function$;

-- um POST /schedule_groups com todos os serviços da comanda
create or replace function public.belasis_enfileirar_agendamento(p_pre_id bigint, p_cliente_id integer)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  p      public.pre_agendamentos;
  v_obs  text;
  v_cal  jsonb;
begin
  select * into p from public.pre_agendamentos where id = p_pre_id;
  select 'Pré-agendamento pelo WhatsApp (assistente IA). Pedido: '
         || string_agg(m.servico || coalesce(' com ' || m.profissional, ''), '; ' order by m.hora_inicio, m.id)
         || coalesce('. Obs.: ' || string_agg(m.observacao, '; ' order by m.id), ''),
         jsonb_agg(jsonb_build_object(
           'inventory_product_id', m.servico_id, 'employee_id', m.profissional_id,
           'start_hour', to_char(m.hora_inicio, 'HH24:MI'), 'end_hour', to_char(m.hora_fim, 'HH24:MI'),
           'reminder', true) order by m.hora_inicio, m.id)
    into v_obs, v_cal
    from public.pre_agendamentos m
   where m.comanda_id = p_pre_id and m.estado <> 'cancelado';

  update public.pre_agendamentos set belasis_cliente_id = p_cliente_id, escrita_estado = 'na_fila', atualizado_em = now()
   where comanda_id = p_pre_id and estado <> 'cancelado';
  insert into public.belasis_fila (chave, caminho, metodo, corpo, pre_agendamento_id)
  values ('escrita_agendamento:' || p_pre_id, '/schedule_groups', 'POST',
          jsonb_build_object('client_id', p_cliente_id, 'date', p.data,
                             'status', coalesce(public.cfg('belasis_status_agendamento') #>> '{}', 'unconfirmed'),
                             'observation', left(v_obs, 500),
                             'calendars_attributes', v_cal),
          p_pre_id)
  on conflict (chave) do nothing;
end;
$function$;

-- falha da comanda: marca todos os itens e avisa a equipe uma vez, com todos os serviços
create or replace function public.belasis_escrita_falhou(p_pre_id bigint, p_erro text)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  p      public.pre_agendamentos;
  v_itens text;
begin
  update public.pre_agendamentos set escrita_estado = 'falhou', escrita_erro = left(p_erro, 500), atualizado_em = now()
   where (id = p_pre_id or comanda_id = p_pre_id) and estado <> 'cancelado';
  select * into p from public.pre_agendamentos where id = p_pre_id;
  if p.id is null then return; end if;
  select string_agg(format('%s%s às %s', m.servico, coalesce(' com ' || m.profissional, ''), to_char(m.hora_inicio, 'HH24:MI')),
                    E'\n' order by m.hora_inicio, m.id)
    into v_itens
    from public.pre_agendamentos m where (m.id = p_pre_id or m.comanda_id = p_pre_id) and m.estado <> 'cancelado';
  perform public.encaminhar_seguro('pre_agendamento_falhou', p.conversa_id, 'Lançar manualmente no Belasis',
    'Comanda de ' || public.data_curta_pt(p.data) || E':\n' || coalesce(v_itens, p.servico)
    || E'\nNão consegui lançar sozinho: ' || coalesce(left(p_erro, 200), 'erro desconhecido')
    || E'\nLance no Belasis em UMA comanda, como NÃO CONFIRMADO, e confirme com a cliente.',
    p.confirmacao_cliente);
end;
$function$;

create or replace function public.belasis_registrar_escrita(f belasis_fila, p_status integer, p_resposta jsonb, p_erro text)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  v_tipo text := split_part(f.chave, ':', 1);
  p      public.pre_agendamentos;
  c      public.conversas;
  v_cli  integer;
  v_itens text;
  x      jsonb;
begin
  if p_status = 429 then
    update public.belasis_fila set estado = 'pendente' where id = f.id;
    return;
  end if;
  if v_tipo = 'escrita_cancelar' then
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
  select * into p from public.pre_agendamentos where id = f.pre_agendamento_id;
  select * into c from public.conversas where id = p.conversa_id;

  if v_tipo = 'escrita_cliente' then
    if p_status between 200 and 299 and (p_resposta->>'id') is not null then
      v_cli := (p_resposta->>'id')::int;
      insert into public.belasis_clientes (id, primeiro_nome, telefones, ativo, atualizado_em)
      values (v_cli, initcap(split_part(btrim(coalesce(p_resposta->>'name', '')), ' ', 1)),
              array_remove(array[public.belasis_tel(p_resposta->>'cellphone'), public.belasis_tel(p_resposta->>'phone'), c.telefone], null),
              true, now())
      on conflict (id) do nothing;
      perform public.belasis_enfileirar_agendamento(p.id, v_cli);
    elsif p_status = 422 then
      insert into public.belasis_fila (chave, caminho, query, pre_agendamento_id)
      values ('escrita_busca:' || p.id, '/clients', jsonb_build_object('search', right(c.telefone, 8), 'limit', 20), p.id)
      on conflict (chave) do nothing;
    else
      perform public.belasis_escrita_falhou(p.id, 'cadastro da cliente: ' || coalesce(p_erro, 'HTTP ' || p_status));
    end if;

  elsif v_tipo = 'escrita_busca' then
    if p_status between 200 and 299 then
      for x in select * from jsonb_array_elements(coalesce(p_resposta->'data', '[]')) loop
        if array_remove(array[public.belasis_tel(x->>'cellphone'), public.belasis_tel(x->>'phone')], null)
           && public.variantes_telefone(c.telefone) then
          v_cli := (x->>'id')::int;
          exit;
        end if;
      end loop;
    end if;
    if v_cli is not null then
      perform public.belasis_enfileirar_agendamento(p.id, v_cli);
    else
      perform public.belasis_escrita_falhou(p.id, 'não consegui cadastrar nem achar a cliente: ' || coalesce(p_erro, 'HTTP ' || p_status));
    end if;

  elsif v_tipo = 'escrita_agendamento' then
    if p_status between 200 and 299 and (p_resposta->>'id') is not null then
      update public.pre_agendamentos
         set estado = 'lancado', escrita_estado = 'lancado', escrita_erro = null,
             belasis_agendamento_id = (p_resposta->>'id')::int, lancado_em = now(), atualizado_em = now()
       where (id = p.id or comanda_id = p.id) and estado <> 'cancelado';
      update public.conversas set belasis_cliente_id = coalesce(belasis_cliente_id, (p_resposta->>'client_id')::int) where id = p.conversa_id;
      select string_agg(format('%s com %s às %s',
               coalesce((select descricao from public.belasis_servicos where id = m.servico_id), m.servico),
               coalesce((select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = m.profissional_id), '?'),
               to_char(m.hora_inicio, 'HH24:MI')), E'\n' order by m.hora_inicio, m.id)
        into v_itens
        from public.pre_agendamentos m where (m.id = p.id or m.comanda_id = p.id) and m.estado <> 'cancelado';
      perform public.encaminhar_seguro('pre_agendamento_lancado', p.conversa_id, 'Já está no Belasis como NÃO CONFIRMADO (comanda única)',
        'Comanda de ' || public.data_curta_pt(p.data) || E':\n' || coalesce(v_itens, p.servico)
        || E'\nConfira a agenda e confirme no Belasis e com a cliente.',
        p.confirmacao_cliente);
    else
      perform public.belasis_escrita_falhou(p.id, 'agendamento: ' || coalesce(p_erro, 'HTTP ' || p_status));
    end if;
  end if;
end;
$function$;

-- conciliação antiga (lançamento manual) não pode "casar" item que ainda vai sair na comanda
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
     where p.estado = 'pendente' and p.escrita_estado is null
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

-- cancelar logo depois de pedir (comanda ainda não lançada): só tira da comanda
create or replace function public.cancelar_agendamento_whatsapp(p_conversa_id uuid, p_data date default null)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v record;
  pa public.pre_agendamentos;
begin
  select * into pa from public.pre_agendamentos
   where conversa_id = p_conversa_id and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado'
     and (p_data is null or data = p_data)
   order by data, hora_inicio limit 1;
  if pa.id is not null then
    update public.pre_agendamentos set estado = 'cancelado', escrita_estado = 'cancelado', atualizado_em = now()
     where conversa_id = p_conversa_id and data = pa.data and escrita_estado = 'aguardando_comanda';
    return jsonb_build_object('ok', true, 'cancelado', true, 'dia', public.data_curta_pt(pa.data),
      'hora', public.hora_curta(pa.hora_inicio), 'servico', pa.servico, 'profissional', pa.profissional,
      'orientacao', 'Confirme que desmarcou, com carinho, e pergunte se quer remarcar.');
  end if;

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

-- remarcar antes de a comanda sair: o item antigo do mesmo serviço sai da comanda
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  if position('aguardando_comanda' in d) > 0 then return; end if;
  d := replace(d, $x$  if p_remarcar then
$x$, $x$  if p_remarcar then
    update public.pre_agendamentos set estado = 'cancelado', escrita_estado = 'cancelado', atualizado_em = now()
     where conversa_id = p_conversa_id and servico_id = v_serv and escrita_estado = 'aguardando_comanda';
  end if;
  -- se o horário antigo ainda não tinha saído na comanda, não há nada a cancelar no Belasis
  if p_remarcar and not found then
$x$);
  if position('aguardando_comanda' in d) = 0 then raise exception 'agendar_whatsapp: trecho não encontrado'; end if;
  execute d;
end $$;

select cron.schedule('belasis-comandas', '* * * * *', 'select public.belasis_processar_comandas()');
