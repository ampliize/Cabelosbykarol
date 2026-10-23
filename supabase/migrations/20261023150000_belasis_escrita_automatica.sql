-- Pré-agendamento do WhatsApp entra sozinho no Belasis como NÃO CONFIRMADO.
--
-- Fluxo: cliente dá o ok → criar_pre_agendamento → (trigger) belasis_preparar_escrita
--   resolve serviço/profissional/duração → cliente existe no Belasis?
--     sim → POST /schedule_groups            (fila: escrita_agendamento:<pre>)
--     não → POST /clients → POST /schedule_groups (se o celular já existir: busca e reaproveita)
--   sucesso → pre_agendamentos.estado = 'lancado' + aviso à equipe ("já está no Belasis, conferir e confirmar")
--   falha   → aviso à equipe para lançar manualmente (nada se perde)
--
-- Travas:
--   * config belasis_escrita_automatica (true/false) — desliga tudo na hora
--   * a Edge Function só aceita POST /clients e POST /schedule_groups; nunca PATCH/DELETE
--   * POST nunca é repetido automaticamente (evita agendamento duplicado)
--   * config belasis_escrita_profissional_teste: enquanto preenchida, todo agendamento vai para esse
--     profissional (teste sem mexer na agenda real); a profissional pedida fica na observação

alter table public.belasis_fila
  add column if not exists metodo text not null default 'GET',
  add column if not exists corpo jsonb,
  add column if not exists pre_agendamento_id bigint;

alter table public.pre_agendamentos
  add column if not exists escrita_estado text,
  add column if not exists escrita_erro text;

insert into public.config_bot (chave, valor, descricao) values
  ('belasis_escrita_automatica', 'true'::jsonb, 'Lança o pré-agendamento do WhatsApp no Belasis como NÃO CONFIRMADO automaticamente'),
  ('belasis_escrita_profissional_teste', '172890'::jsonb, 'Durante o teste, todo agendamento automático vai para este profissional do Belasis (null = profissional real)')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

-- serviço do catálogo que melhor corresponde ao texto do agente
create or replace function public.belasis_resolver_servico(p_texto text)
returns integer
language sql
stable
set search_path to ''
as $function$
  with base as (
    select t from regexp_split_to_table(lower(extensions.unaccent(coalesce(p_texto, ''))), '[^a-z0-9]+') t where length(t) >= 3
  ), termos as (
    select t from base
    union
    select s.para from base join (values ('progressiva', 'selagem'), ('alisamento', 'selagem'),
                                         ('alisar', 'selagem'), ('mega', 'alongamento'),
                                         ('aplique', 'alongamento')) s(de, para) on s.de = base.t
  ), cand as (
    select s.id,
           (select count(*) from termos where lower(extensions.unaccent(s.descricao)) like '%' || termos.t || '%') acertos,
           (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
             where (it->>'servico_id')::int = s.id and a.data >= current_date - 120 and a.status <> 'removido') feitos
      from public.belasis_servicos s
     where s.ativo
  )
  select id from cand where acertos > 0 order by acertos desc, feitos desc, id limit 1;
$function$;

-- profissional ativa pelo nome/apelido que a cliente falou
create or replace function public.belasis_resolver_profissional(p_nome text)
returns integer
language sql
stable
set search_path to ''
as $function$
  with n as (select lower(extensions.unaccent(btrim(coalesce(p_nome, '')))) v)
  select p.id
    from public.belasis_profissionais p, n
   where p.ativo and n.v <> '' and p.nome <> 'Ateliê'
     and (lower(extensions.unaccent(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))) = n.v
          or lower(extensions.unaccent(coalesce(p.apelido, ''))) = n.v
          or lower(extensions.unaccent(split_part(p.nome, ' ', 1))) = n.v
          or lower(extensions.unaccent(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))) like n.v || '%')
   order by (lower(extensions.unaccent(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome))) = n.v) desc, p.id
   limit 1;
$function$;

-- sem preferência: quem mais faz o serviço e está livre no horário (pela grade sincronizada)
create or replace function public.belasis_escolher_profissional(p_servico_id integer, p_data date, p_hora time)
returns integer
language sql
stable
set search_path to ''
as $function$
  with quem as (
    select (it->>'profissional_id')::int pid, count(*) n
      from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
     where (it->>'servico_id')::int = p_servico_id and a.data >= current_date - 120 and a.status not in ('disconfirm', 'removido')
     group by 1
  )
  select q.pid
    from quem q join public.belasis_profissionais p on p.id = q.pid and p.ativo and p.nome <> 'Ateliê'
    left join public.belasis_horarios_livres h on h.profissional_id = q.pid and h.data = p_data
   order by exists (select 1 from jsonb_array_elements(coalesce(h.slots, '[]')) s
                     where s->>'hour' = to_char(p_hora, 'HH24:MI') and s->>'label' = 'available') desc,
            q.n desc
   limit 1;
$function$;

create or replace function public.belasis_enfileirar_agendamento(p_pre_id bigint, p_cliente_id integer)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  p public.pre_agendamentos;
  v_obs text;
begin
  select * into p from public.pre_agendamentos where id = p_pre_id;
  v_obs := 'Pré-agendamento pelo WhatsApp (assistente IA) - conferir e confirmar com a cliente.'
           || coalesce(' Pedido: ' || p.servico, '')
           || coalesce(' com ' || p.profissional, '')
           || coalesce('. Obs.: ' || p.observacao, '');
  update public.pre_agendamentos set belasis_cliente_id = p_cliente_id, escrita_estado = 'na_fila', atualizado_em = now()
   where id = p_pre_id;
  insert into public.belasis_fila (chave, caminho, metodo, corpo, pre_agendamento_id)
  values ('escrita_agendamento:' || p_pre_id, '/schedule_groups', 'POST',
          jsonb_build_object('client_id', p_cliente_id, 'date', p.data, 'status', 'unconfirmed',
                             'observation', left(v_obs, 500),
                             'calendars_attributes', jsonb_build_array(jsonb_build_object(
                               'inventory_product_id', p.servico_id, 'employee_id', p.profissional_id,
                               'start_hour', to_char(p.hora_inicio, 'HH24:MI'), 'end_hour', to_char(p.hora_fim, 'HH24:MI'),
                               'reminder', true))),
          p_pre_id)
  on conflict (chave) do nothing;
end;
$function$;

create or replace function public.belasis_escrita_falhou(p_pre_id bigint, p_erro text)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  p public.pre_agendamentos;
begin
  update public.pre_agendamentos set escrita_estado = 'falhou', escrita_erro = left(p_erro, 500), atualizado_em = now()
   where id = p_pre_id returning * into p;
  if p.id is null then return; end if;
  perform public.encaminhar_para_responsavel('pre_agendamento_falhou', p.conversa_id, 'Lançar manualmente no Belasis',
    format('Pedido: %s%s, %s às %s', p.servico, coalesce(' com ' || p.profissional, ''),
           to_char(p.data, 'DD/MM (TMDy)'), to_char(p.hora_inicio, 'HH24:MI'))
    || E'\nNão consegui lançar sozinho: ' || coalesce(left(p_erro, 200), 'erro desconhecido')
    || E'\nLance no Belasis como NÃO CONFIRMADO e confirme com a cliente.',
    p.confirmacao_cliente);
end;
$function$;

-- prepara e põe na fila a escrita de um pré-agendamento
create or replace function public.belasis_preparar_escrita(p_pre_id bigint)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  p        public.pre_agendamentos;
  c        public.conversas;
  v_serv   integer;
  v_prof   integer;
  v_dur    integer;
  v_cli    integer;
  v_teste  integer := nullif(public.cfg('belasis_escrita_profissional_teste') #>> '{}', '')::int;
begin
  select * into p from public.pre_agendamentos where id = p_pre_id;
  if p.id is null then return jsonb_build_object('ok', false, 'erro', 'pre_agendamento_inexistente'); end if;
  select * into c from public.conversas where id = p.conversa_id;

  v_serv := coalesce(p.servico_id, public.belasis_resolver_servico(p.servico));
  if v_serv is null then
    perform public.belasis_escrita_falhou(p_pre_id, 'serviço "' || coalesce(p.servico, '?') || '" não encontrado no catálogo');
    return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado');
  end if;
  select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;

  v_prof := coalesce(v_teste, p.profissional_id, public.belasis_resolver_profissional(p.profissional),
                     public.belasis_escolher_profissional(v_serv, p.data, p.hora_inicio));
  if v_prof is null then
    perform public.belasis_escrita_falhou(p_pre_id, 'não achei profissional para o serviço');
    return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrado');
  end if;

  update public.pre_agendamentos
     set servico_id = v_serv, profissional_id = v_prof,
         hora_fim = coalesce(hora_fim, hora_inicio + make_interval(mins => greatest(v_dur, 15))),
         escrita_estado = 'na_fila', atualizado_em = now()
   where id = p_pre_id;

  select bc.id into v_cli from public.belasis_clientes bc
   where bc.telefones && public.variantes_telefone(c.telefone) order by bc.ativo desc, bc.id desc limit 1;

  if v_cli is not null then
    perform public.belasis_enfileirar_agendamento(p_pre_id, v_cli);
  else
    insert into public.belasis_fila (chave, caminho, metodo, corpo, pre_agendamento_id)
    values ('escrita_cliente:' || p_pre_id, '/clients', 'POST',
            jsonb_build_object('name', coalesce(nullif(btrim(c.nome), ''), nullif(btrim(c.push_name), ''), 'Cliente WhatsApp'),
                               'phone', c.telefone, 'cellphone', c.telefone,
                               'observation', 'Cadastrada pelo assistente WhatsApp'),
            p_pre_id)
    on conflict (chave) do nothing;
  end if;

  perform public.belasis_disparar_sync();
  return jsonb_build_object('ok', true, 'servico_id', v_serv, 'profissional_id', v_prof, 'cliente_id', v_cli);
end;
$function$;

create or replace function public.tg_pre_agendamento_escrita()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if coalesce((public.cfg('belasis_escrita_automatica'))::boolean, false) then
    begin
      perform public.belasis_preparar_escrita(new.id);
    exception when others then
      perform public.belasis_escrita_falhou(new.id, 'erro interno: ' || sqlerrm);
    end;
  end if;
  return null;
end;
$function$;

create or replace trigger tg_pre_agendamento_escrita after insert on public.pre_agendamentos
  for each row execute function public.tg_pre_agendamento_escrita();

-- resposta de uma escrita (chamada pela belasis_registrar_resposta)
create or replace function public.belasis_registrar_escrita(f public.belasis_fila, p_status integer, p_resposta jsonb, p_erro text)
returns void
language plpgsql
set search_path to ''
as $function$
declare
  v_tipo text := split_part(f.chave, ':', 1);
  p      public.pre_agendamentos;
  c      public.conversas;
  v_cli  integer;
  x      jsonb;
begin
  if p_status = 429 then
    update public.belasis_fila set estado = 'pendente' where id = f.id;
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
      -- celular já cadastrado com outro formato: procura e reaproveita
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
       where id = p.id returning * into p;
      update public.conversas set belasis_cliente_id = coalesce(belasis_cliente_id, (p_resposta->>'client_id')::int) where id = p.conversa_id;
      perform public.encaminhar_para_responsavel('pre_agendamento_lancado', p.conversa_id, 'Já está no Belasis como NÃO CONFIRMADO',
        format('%s com %s, %s às %s',
               coalesce((select descricao from public.belasis_servicos where id = p.servico_id), p.servico),
               coalesce((select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = p.profissional_id), '?'),
               to_char(p.data, 'DD/MM (TMDy)'), to_char(p.hora_inicio, 'HH24:MI'))
        || coalesce(E'\nPreferência da cliente: ' || p.profissional, '')
        || E'\nConfira a agenda e confirme no Belasis e com a cliente.',
        p.confirmacao_cliente);
    else
      perform public.belasis_escrita_falhou(p.id, 'agendamento: ' || coalesce(p_erro, 'HTTP ' || p_status));
    end if;
  end if;
end;
$function$;

do $$
declare d text;
begin
  -- registrar_resposta: escritas vão para belasis_registrar_escrita
  d := pg_get_functiondef('public.belasis_registrar_resposta(bigint,integer,jsonb,text)'::regprocedure);
  if position('belasis_registrar_escrita' in d) = 0 then
    d := replace(d, $x$  returning * into f;
$x$, $x$  returning * into f;

  if f.chave like 'escrita_%' then
    perform public.belasis_registrar_escrita(f, p_status, p_resposta, p_erro);
    return;
  end if;
$x$);
    if position('belasis_registrar_escrita' in d) = 0 then raise exception 'registrar_resposta: trecho não encontrado'; end if;
    execute d;
  end if;

  -- criar_pre_agendamento: com escrita automática, o aviso sai depois do resultado (lançado ou falhou)
  d := pg_get_functiondef('public.criar_pre_agendamento(uuid,text,date,time without time zone,text,integer,integer,time without time zone,text,text)'::regprocedure);
  if position('belasis_escrita_automatica' in d) = 0 then
    d := replace(d, $x$  perform public.encaminhar_para_responsavel('pre_agendamento', p_conversa_id,
                                              'Pré-agendamento para validar', v_res, p_confirmacao_cliente);$x$,
                    $x$  if not coalesce((public.cfg('belasis_escrita_automatica'))::boolean, false) then
    perform public.encaminhar_para_responsavel('pre_agendamento', p_conversa_id,
                                                'Pré-agendamento para validar', v_res, p_confirmacao_cliente);
  end if;$x$);
    if position('belasis_escrita_automatica' in d) = 0 then raise exception 'criar_pre_agendamento: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

-- fila: escritas primeiro; POST nunca é reprocessado sozinho
create or replace function public.belasis_proximos(p_limite integer default 15)
returns setof public.belasis_fila
language sql
set search_path to ''
as $function$
  update public.belasis_fila f
     set estado = 'processando', tentativas = tentativas + 1
   where f.id in (select id from public.belasis_fila
                   where estado = 'pendente'
                      or (estado = 'processando' and processado_em is null and metodo = 'GET'
                          and criado_em < now() - interval '10 minutes' and tentativas < 3)
                   order by (chave like 'escrita_%') desc, (chave like '%#agora%') desc, (chave like 'agenda:%') desc, id
                   limit p_limite for update skip locked)
  returning f.*;
$function$;

-- log com método real
create or replace function public.belasis_log_chamada(p_metodo text, p_caminho text, p_status integer, p_ms integer, p_erro text default null)
returns void
language sql
set search_path to ''
as $function$
  insert into public.belasis_chamadas (metodo, rota, origem, modo, permitido, status_http, duracao_ms, erro)
  values (p_metodo, public.belasis_rota(p_caminho), case when p_metodo = 'GET' then 'sync' else 'escrita_automatica' end,
          coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado'), true, p_status, p_ms, left(p_erro, 500));
$function$;
