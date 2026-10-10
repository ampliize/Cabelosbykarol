-- =====================================================================
-- Sincronização Belasis v2: tudo o que a API permite ler + atualização
-- automática (a API não tem webhooks, então lemos em ciclos):
--   catalogo  a cada 15 min  → serviços (preço, duração, ativo) e profissionais
--   agenda    a cada 10 min  → agendamentos de −3 a +60 dias (novos, alterados, cancelados, apagados)
--   completa  todo dia 05:30 → tudo: clientes, agenda −365/+60, categorias,
--                              serviços por profissional, grade de 14 dias
-- Ao fim de cada ciclo, o que sumiu do Belasis é desativado aqui.
-- =====================================================================

alter table public.belasis_profissionais add column if not exists apelido_belasis text;
alter table public.belasis_profissionais add column if not exists profissao text;
alter table public.belasis_servicos add column if not exists favorito boolean;

create table if not exists public.belasis_grupos (
  id            integer primary key,
  nome          text not null,
  ativo         boolean,
  atualizado_em timestamptz not null default now()
);
alter table public.belasis_grupos enable row level security;
revoke all on public.belasis_grupos from anon, authenticated;

create table if not exists public.belasis_rodadas (
  sufixo        text primary key,
  tipo          text not null check (tipo in ('completa', 'catalogo', 'agenda')),
  janela_ini    date,
  janela_fim    date,
  iniciada_em   timestamptz not null default now(),
  finalizada_em timestamptz,
  resumo        jsonb
);
alter table public.belasis_rodadas enable row level security;
revoke all on public.belasis_rodadas from anon, authenticated;

-- Nome curto: apelido manual > apelido do Belasis (sem ".mani"/" Aux") > primeiro nome.
create or replace function public.belasis_nome_curto(p_apelido text, p_apelido_belasis text, p_nome text)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(nullif(btrim(p_apelido), ''),
                  nullif(btrim(regexp_replace(coalesce(p_apelido_belasis, ''), '(\.mani|\.Mani|\s+aux)$', '', 'i')), ''),
                  split_part(btrim(coalesce(p_nome, '')), ' ', 1));
$$;

create or replace function public.belasis_registrar_resposta(
  p_id bigint, p_status integer, p_resposta jsonb, p_erro text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  f      public.belasis_fila;
  r      public.belasis_rodadas;
  dados  jsonb;
  total  integer;
  lim    integer;
  pg     integer;
  e      jsonb;
  hoje   date := (now() at time zone 'America/Maceio')::date;
  d      date;
  n      integer;
  v_tipo text;
  v_base text;
  v_suf  text;
begin
  update public.belasis_fila
     set estado = case when p_status between 200 and 299 then 'ok' else 'erro' end,
         status_http = p_status, erro = left(p_erro, 500), processado_em = now(),
         resposta = case when chave like 'servicos:%' or chave like 'profissionais:%' then p_resposta else null end
   where id = p_id
  returning * into f;

  if f.id is null or p_status not between 200 and 299 then
    if p_status = 429 then
      update public.belasis_fila set estado = 'pendente' where id = p_id;
    end if;
    return;
  end if;

  v_base := split_part(f.chave, '#', 1);
  v_suf  := case when position('#' in f.chave) > 0 then '#' || split_part(f.chave, '#', 2) else '' end;
  v_tipo := split_part(v_base, ':', 1);
  select * into r from public.belasis_rodadas where sufixo = split_part(f.chave, '#', 2);

  dados := case when jsonb_typeof(p_resposta) = 'array' then p_resposta else coalesce(p_resposta->'data', '[]') end;
  total := (p_resposta->>'total')::int;
  lim   := coalesce((p_resposta->>'limit')::int, 100);
  pg    := coalesce((f.query->>'page')::int, 1);

  if pg = 1 and total is not null and total > lim and v_tipo in ('servicos','profissionais','clientes','agenda') then
    for n in 2 .. least(ceil(total::numeric / lim)::int, 150) loop
      perform public.belasis_enfileirar(v_tipo || ':' || n || v_suf, f.caminho, f.query || jsonb_build_object('page', n));
    end loop;
  end if;

  case v_tipo
  when 'servicos' then
    insert into public.belasis_servicos as s (id, descricao, preco_cents, duracao_min, ativo, online, group_id, favorito, atualizado_em)
    select (x->>'id')::int, x->>'description', (x->>'price_cents')::int, ((x->>'duration')::int / 60),
           coalesce((x->>'active')::boolean, true), coalesce((x->>'available_to_online_scheduling')::boolean, false),
           (x->>'group_id')::int, (x->>'favorite')::boolean, now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set descricao = excluded.descricao, preco_cents = excluded.preco_cents,
      duracao_min = excluded.duracao_min, ativo = excluded.ativo, online = excluded.online,
      group_id = excluded.group_id, favorito = excluded.favorito, atualizado_em = now();
    -- categoria nova (ou rodada completa): busca o nome
    for e in select distinct jsonb_build_object('g', x->'group_id') from jsonb_array_elements(dados) x
              where x->>'group_id' is not null loop
      if coalesce(r.tipo, 'completa') = 'completa'
         or not exists (select 1 from public.belasis_grupos g where g.id = (e->>'g')::int) then
        perform public.belasis_enfileirar('grupo:' || (e->>'g') || v_suf, '/inventory/groups/' || (e->>'g'), '{}');
      end if;
    end loop;

  when 'grupo' then
    insert into public.belasis_grupos as g (id, nome, ativo, atualizado_em)
    values ((p_resposta->>'id')::int, p_resposta->>'name', (p_resposta->>'active')::boolean, now())
    on conflict (id) do update set nome = excluded.nome, ativo = excluded.ativo, atualizado_em = now();

  when 'profissionais' then
    insert into public.belasis_profissionais as p (id, nome, apelido_belasis, profissao, ativo, atualizado_em)
    select (x->>'id')::int, x->>'name', nullif(btrim(x->>'nickname'), ''), x->>'profession',
           coalesce((x->>'active')::boolean, true), now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set nome = excluded.nome, apelido_belasis = excluded.apelido_belasis,
      profissao = excluded.profissao, ativo = excluded.ativo, atualizado_em = now();
    if coalesce(r.tipo, 'completa') = 'completa' then
      for e in select * from jsonb_array_elements(dados)
                where coalesce((value->>'active')::boolean, true)
                  and coalesce(value->>'profession', '') !~* 'recep' loop
        perform public.belasis_enfileirar('prof_servicos:' || (e->>'id') || v_suf, '/employees/' || (e->>'id') || '/services',
                                          '{"limit":100,"page":1}');
        for n in 1 .. 16 loop
          d := hoje + n;
          if extract(dow from d) not in (0, 1) then
            perform public.belasis_enfileirar('livres:' || (e->>'id') || ':' || d || v_suf,
                                              '/employees/' || (e->>'id') || '/free_times', jsonb_build_object('date', d));
          end if;
        end loop;
      end loop;
    end if;

  when 'prof_servicos' then
    update public.belasis_profissional_servicos set ativo = false, atualizado_em = now()
     where profissional_id = split_part(v_base, ':', 2)::int and pg = 1;
    insert into public.belasis_profissional_servicos as v (profissional_id, servico_id, ativo, atualizado_em)
    select split_part(v_base, ':', 2)::int, (x->>'id')::int, true, now()
      from jsonb_array_elements(dados) x
     where x ? 'id' and split_part(v_base, ':', 2)::int in (select id from public.belasis_profissionais)
    on conflict (profissional_id, servico_id) do update set ativo = true, atualizado_em = now();

  when 'livres' then
    insert into public.belasis_horarios_livres (profissional_id, data, slots, atualizado_em)
    values (split_part(v_base, ':', 2)::int, split_part(v_base, ':', 3)::date, dados, now())
    on conflict (profissional_id, data) do update set slots = excluded.slots, atualizado_em = now();

  when 'clientes' then
    insert into public.belasis_clientes as c (id, primeiro_nome, telefones, aniversario, ativo, atualizado_em)
    select (x->>'id')::int,
           initcap(split_part(btrim(coalesce(nullif(btrim(x->>'nickname'), ''), x->>'name', '')), ' ', 1)),
           array_remove(array[public.belasis_tel(x->>'cellphone'), public.belasis_tel(x->>'phone')], null),
           case when x->>'birthday' ~ '^\d{4}-\d{2}-\d{2}$' then (x->>'birthday')::date end,
           coalesce((x->>'active')::boolean, true), now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set primeiro_nome = excluded.primeiro_nome, telefones = excluded.telefones,
      aniversario = excluded.aniversario, ativo = excluded.ativo, atualizado_em = now();

  when 'agenda' then
    insert into public.belasis_agendamentos as a (id, cliente_id, data, status, observacao, itens, atualizado_em)
    select (x->>'id')::int, (x->>'client_id')::int, (x->>'date')::date, x->>'status', x->>'observation',
           coalesce((select jsonb_agg(jsonb_build_object(
                        'servico_id', (c->>'inventory_product_id')::int,
                        'profissional_id', (c->>'employee_id')::int,
                        'inicio', c->>'start_hour', 'fim', c->>'end_hour',
                        'lembrete', (c->>'reminder')::boolean))
                       from jsonb_array_elements(coalesce(x->'calendars', '[]')) c), '[]'),
           now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set cliente_id = excluded.cliente_id, data = excluded.data, status = excluded.status,
      observacao = excluded.observacao, itens = excluded.itens, atualizado_em = now();

  else
    null;
  end case;
end;
$$;

-- Inicia um ciclo. Não abre outro do mesmo tipo enquanto o anterior não terminou (até 2 h).
create or replace function public.belasis_iniciar_sync(p_tipo text default 'completa')
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  hoje   date := (now() at time zone 'America/Maceio')::date;
  v_suf  text := p_tipo || to_char(clock_timestamp(), 'YYYYMMDDHH24MISS');
  v_ini  date;
  v_fim  date;
begin
  if p_tipo not in ('completa', 'catalogo', 'agenda') then
    raise exception 'tipo inválido: %', p_tipo;
  end if;
  if coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado') = 'desligado' then
    return jsonb_build_object('ok', false, 'motivo', 'belasis_desligado');
  end if;
  if exists (select 1 from public.belasis_rodadas
              where tipo = p_tipo and finalizada_em is null and iniciada_em > now() - interval '2 hours') then
    return jsonb_build_object('ok', false, 'motivo', 'ciclo_anterior_em_andamento');
  end if;

  if p_tipo = 'completa' then v_ini := hoje - 365; v_fim := hoje + 60;
  elsif p_tipo = 'agenda' then v_ini := hoje - 3; v_fim := hoje + 60;
  end if;

  insert into public.belasis_rodadas (sufixo, tipo, janela_ini, janela_fim) values (v_suf, p_tipo, v_ini, v_fim);

  if p_tipo in ('completa', 'catalogo') then
    perform public.belasis_enfileirar('servicos:1#' || v_suf, '/inventory/services', '{"limit":100,"page":1}');
    perform public.belasis_enfileirar('profissionais:1#' || v_suf, '/employees', '{"limit":100,"page":1}');
  end if;
  if p_tipo = 'completa' then
    perform public.belasis_enfileirar('clientes:1#' || v_suf, '/clients', '{"limit":100,"page":1}');
  end if;
  if p_tipo in ('completa', 'agenda') then
    perform public.belasis_enfileirar('agenda:1#' || v_suf, '/schedule_groups',
      jsonb_build_object('limit', 100, 'page', 1, 'start_date', v_ini, 'end_date', v_fim));
  end if;
  return jsonb_build_object('ok', true, 'rodada', v_suf);
end;
$$;

-- Fecha ciclos terminados e desativa o que sumiu do Belasis.
create or replace function public.belasis_finalizar_rodadas()
returns integer
language plpgsql
set search_path = ''
as $$
declare
  r       public.belasis_rodadas;
  n       integer := 0;
  v_ok    boolean;
  v_res   jsonb;
  c       integer;
begin
  for r in select * from public.belasis_rodadas where finalizada_em is null order by iniciada_em loop
    continue when exists (select 1 from public.belasis_fila
                           where chave like '%#' || r.sufixo and estado in ('pendente', 'processando'));
    v_res := '{}';

    -- Serviços que não vieram nesta leitura completa do catálogo → inativos
    select bool_and(estado = 'ok') into v_ok from public.belasis_fila
     where chave like 'servicos:%#' || r.sufixo;
    if coalesce(v_ok, false) then
      update public.belasis_servicos set ativo = false, atualizado_em = now()
       where ativo and atualizado_em < r.iniciada_em;
      get diagnostics c = row_count; v_res := v_res || jsonb_build_object('servicos_desativados', c);
    end if;

    select bool_and(estado = 'ok') into v_ok from public.belasis_fila
     where chave like 'profissionais:%#' || r.sufixo;
    if coalesce(v_ok, false) then
      update public.belasis_profissionais set ativo = false, atualizado_em = now()
       where ativo and atualizado_em < r.iniciada_em;
      get diagnostics c = row_count; v_res := v_res || jsonb_build_object('profissionais_desativadas', c);
    end if;

    -- Agendamentos da janela que não vieram → apagados no Belasis
    select bool_and(estado = 'ok') into v_ok from public.belasis_fila
     where chave like 'agenda:%#' || r.sufixo;
    if coalesce(v_ok, false) and r.janela_ini is not null then
      update public.belasis_agendamentos set status = 'removido', atualizado_em = now()
       where data between r.janela_ini and r.janela_fim and status <> 'removido' and atualizado_em < r.iniciada_em;
      get diagnostics c = row_count; v_res := v_res || jsonb_build_object('agendamentos_removidos', c);
    end if;

    v_res := v_res || jsonb_build_object(
      'leituras', (select count(*) from public.belasis_fila where chave like '%#' || r.sufixo),
      'erros', (select count(*) from public.belasis_fila where chave like '%#' || r.sufixo and estado = 'erro'));
    update public.belasis_rodadas set finalizada_em = now(), resumo = v_res where sufixo = r.sufixo;
    -- respostas cruas não são mais necessárias
    update public.belasis_fila set resposta = null where chave like '%#' || r.sufixo and resposta is not null;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- O disparo a cada minuto também fecha os ciclos.
create or replace function public.belasis_disparar_sync()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_secret text;
  v_req    bigint;
begin
  perform public.belasis_finalizar_rodadas();
  if coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado') = 'desligado' then
    return null;
  end if;
  if not exists (select 1 from public.belasis_fila where estado = 'pendente') then
    return null;
  end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'n8n_webhook_retomada_secret';
  select net.http_post(
           url     := 'https://cuofrppbluatjniserio.supabase.co/functions/v1/belasis-sync',
           body    := '{}'::jsonb,
           headers := jsonb_build_object('Content-Type', 'application/json', 'x-cbk-secret', v_secret),
           timeout_milliseconds := 120000
         ) into v_req;
  return v_req;
end;
$$;

-- Ciclos automáticos (substitui o diário antigo pelo mesmo nome).
select cron.schedule('belasis-sync-diario', '30 8 * * *', $$select public.belasis_iniciar_sync('completa'::text)$$);
select cron.schedule('belasis-catalogo', '*/15 * * * *', $$select public.belasis_iniciar_sync('catalogo'::text)$$);
select cron.schedule('belasis-agenda', '*/10 * * * *', $$select public.belasis_iniciar_sync('agenda'::text)$$);

-- Nome curto nas funções do agente (apelido do Belasis entra automaticamente).
do $$
declare
  f text;
  v_def text;
begin
  foreach f in array array['public.perfil_cliente_belasis(text)', 'public.consultar_servicos(text,integer)'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    execute replace(v_def, 'coalesce(p.apelido, split_part(p.nome, '' '', 1))',
                    'public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome)');
  end loop;
end $$;

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('belasis_nome_curto','belasis_registrar_resposta',
              'belasis_iniciar_sync','belasis_finalizar_rodadas','belasis_disparar_sync')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Agendamento apagado no Belasis ("removido") não conta em memória, catálogo nem painel.
do $$
declare
  f text;
  v_def text;
begin
  foreach f in array array['public.perfil_cliente_belasis(text)', 'public.consultar_servicos(text,integer)',
                           'public.dashboard_belasis(integer)'] loop
    v_def := pg_get_functiondef(f::regprocedure);
    v_def := replace(v_def, 'status <> ''disconfirm''', 'status not in (''disconfirm'', ''removido'')');
    v_def := replace(v_def, 'a.status <> ''disconfirm''', 'a.status not in (''disconfirm'', ''removido'')');
    execute v_def;
  end loop;
end $$;
