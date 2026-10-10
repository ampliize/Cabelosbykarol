-- =====================================================================
-- Sincronização Belasis → Supabase (SOMENTE LEITURA, GET)
--
-- Fila de requisições processada pela Edge Function `belasis-sync`
-- (até 15 por execução, 1 execução por minuto pelo pg_cron → ≤ 15 req/min,
-- abaixo do limite de 30/min do Belasis). A chave fica só nos segredos das
-- Edge Functions. Cada resposta é interpretada aqui no banco.
-- =====================================================================

create table public.belasis_fila (
  id           bigint generated always as identity primary key,
  chave        text not null,                 -- ex.: servicos:1, profissionais:1, clientes:3
  caminho      text not null,                 -- ex.: /inventory/services
  query        jsonb not null default '{}',
  estado       text not null default 'pendente' check (estado in ('pendente','processando','ok','erro')),
  tentativas   integer not null default 0,
  status_http  integer,
  resposta     jsonb,
  erro         text,
  criado_em    timestamptz not null default now(),
  processado_em timestamptz,
  unique (chave)
);
create index belasis_fila_pendentes_idx on public.belasis_fila (id) where estado = 'pendente';
alter table public.belasis_fila enable row level security;

create table public.belasis_clientes (
  id              integer primary key,
  primeiro_nome   text,
  telefones       text[] not null default '{}',   -- normalizados (55 + DDD + número)
  aniversario     date,
  ativo           boolean,
  atualizado_em   timestamptz not null default now()
);
create index belasis_clientes_tel_idx on public.belasis_clientes using gin (telefones);
alter table public.belasis_clientes enable row level security;

create table public.belasis_agendamentos (
  id              integer primary key,
  cliente_id      integer,
  data            date,
  status          text,
  observacao      text,
  itens           jsonb not null default '[]',    -- [{servico_id, profissional_id, inicio, fim, lembrete}]
  atualizado_em   timestamptz not null default now()
);
create index belasis_agendamentos_cliente_idx on public.belasis_agendamentos (cliente_id, data desc);
create index belasis_agendamentos_data_idx on public.belasis_agendamentos (data);
alter table public.belasis_agendamentos enable row level security;

create table public.belasis_horarios_livres (
  profissional_id integer not null,
  data            date not null,
  slots           jsonb not null,                 -- [{hour, label}]
  atualizado_em   timestamptz not null default now(),
  primary key (profissional_id, data)
);
alter table public.belasis_horarios_livres enable row level security;

revoke all on public.belasis_fila, public.belasis_clientes, public.belasis_agendamentos,
              public.belasis_horarios_livres from anon, authenticated;

-- Segredo interno (o mesmo dos webhooks n8n) para autenticar o pg_net → Edge Function.
create or replace function public.checar_segredo_interno(p_segredo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from vault.decrypted_secrets
                  where name = 'n8n_webhook_retomada_secret' and decrypted_secret = p_segredo);
$$;

-- Enfileira (sem duplicar) uma requisição GET.
create or replace function public.belasis_enfileirar(p_chave text, p_caminho text, p_query jsonb default '{}')
returns void
language sql
set search_path = ''
as $$
  insert into public.belasis_fila (chave, caminho, query) values (p_chave, p_caminho, coalesce(p_query, '{}'))
  on conflict (chave) do nothing;
$$;

-- Edge Function pega o próximo lote.
create or replace function public.belasis_proximos(p_limite integer default 15)
returns setof public.belasis_fila
language sql
set search_path = ''
as $$
  update public.belasis_fila f
     set estado = 'processando', tentativas = tentativas + 1
   where f.id in (select id from public.belasis_fila
                   where estado = 'pendente' or (estado = 'processando' and processado_em is null
                                                 and criado_em < now() - interval '10 minutes' and tentativas < 3)
                   order by id limit p_limite for update skip locked)
  returning f.*;
$$;

create or replace function public.belasis_tel(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when d ~ '^55[1-9][0-9]9?[0-9]{8}$' then d
    when d ~ '^[1-9][0-9]9?[0-9]{8}$' then '55' || d
    else null end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) t;
$$;

-- Interpreta uma resposta e, se for a 1ª página, enfileira as demais / os detalhes.
create or replace function public.belasis_registrar_resposta(
  p_id bigint, p_status integer, p_resposta jsonb, p_erro text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare
  f      public.belasis_fila;
  dados  jsonb;
  total  integer;
  lim    integer;
  pg     integer;
  e      jsonb;
  hoje   date := (now() at time zone 'America/Maceio')::date;
  d      date;
  n      integer;
  v_tipo text;
  v_base text;   -- chave sem o sufixo da rodada
  v_suf  text;   -- '#AAAAMMDDHHMI' (rodada) ou ''
begin
  update public.belasis_fila
     set estado = case when p_status between 200 and 299 then 'ok' else 'erro' end,
         status_http = p_status, erro = left(p_erro, 500), processado_em = now(),
         resposta = case when chave like 'servicos:%' or chave like 'profissionais:%'
                           or chave like 'prof_servicos:%' or chave like 'livres:%'
                         then p_resposta else null end   -- clientes/agenda não ficam crus na fila
   where id = p_id
  returning * into f;

  if f.id is null or p_status not between 200 and 299 then
    if p_status = 429 then
      update public.belasis_fila set estado = 'pendente' where id = p_id;  -- tenta de novo no próximo minuto
    end if;
    return;
  end if;

  v_base := split_part(f.chave, '#', 1);
  v_suf  := case when position('#' in f.chave) > 0 then '#' || split_part(f.chave, '#', 2) else '' end;
  v_tipo := split_part(v_base, ':', 1);

  dados := case when jsonb_typeof(p_resposta) = 'array' then p_resposta else coalesce(p_resposta->'data', '[]') end;
  total := (p_resposta->>'total')::int;
  lim   := coalesce((p_resposta->>'limit')::int, 100);
  pg    := coalesce((f.query->>'page')::int, 1);

  -- Paginação: na página 1, enfileira as demais (limite de segurança 60 páginas).
  if pg = 1 and total is not null and total > lim and v_tipo in ('servicos','profissionais','clientes','agenda') then
    for n in 2 .. least(ceil(total::numeric / lim)::int, 60) loop
      perform public.belasis_enfileirar(v_tipo || ':' || n || v_suf, f.caminho,
                                        f.query || jsonb_build_object('page', n));
    end loop;
  end if;

  case v_tipo
  when 'servicos' then
    insert into public.belasis_servicos as s (id, descricao, preco_cents, duracao_min, ativo, online, group_id, atualizado_em)
    select (x->>'id')::int, x->>'description', (x->>'price_cents')::int, (x->>'duration')::int,
           coalesce((x->>'active')::boolean, true), coalesce((x->>'available_to_online_scheduling')::boolean, false),
           (x->>'group_id')::int, now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set descricao = excluded.descricao, preco_cents = excluded.preco_cents,
      duracao_min = excluded.duracao_min, ativo = excluded.ativo, online = excluded.online,
      group_id = excluded.group_id, atualizado_em = now();

  when 'profissionais' then
    insert into public.belasis_profissionais as p (id, nome, ativo, atualizado_em)
    select (x->>'id')::int, x->>'name', true, now() from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do update set nome = excluded.nome, ativo = true, atualizado_em = now();
    for e in select * from jsonb_array_elements(dados) loop
      perform public.belasis_enfileirar('prof_servicos:' || (e->>'id') || v_suf, '/employees/' || (e->>'id') || '/services',
                                        '{"limit":100,"page":1}');
      for n in 1 .. 7 loop
        d := hoje + n;
        if extract(dow from d) not in (0, 1) then   -- salão fecha domingo e segunda
          perform public.belasis_enfileirar('livres:' || (e->>'id') || ':' || d || v_suf, '/employees/' || (e->>'id') || '/free_times',
                                            jsonb_build_object('date', d));
        end if;
      end loop;
    end loop;

  when 'prof_servicos' then
    insert into public.belasis_profissional_servicos as v (profissional_id, servico_id, ativo, atualizado_em)
    select split_part(v_base, ':', 2)::int, (x->>'id')::int, true, now()
      from jsonb_array_elements(dados) x
     where x ? 'id' and split_part(v_base, ':', 2)::int in (select id from public.belasis_profissionais)
    on conflict (profissional_id, servico_id) do update set ativo = true, atualizado_em = now();
    -- serviços que só aparecem por profissional também entram no catálogo
    insert into public.belasis_servicos as s (id, descricao, preco_cents, duracao_min, ativo, online, group_id, atualizado_em)
    select (x->>'id')::int, x->>'description', (x->>'price_cents')::int, (x->>'duration')::int,
           coalesce((x->>'active')::boolean, true), coalesce((x->>'available_to_online_scheduling')::boolean, false),
           (x->>'group_id')::int, now()
      from jsonb_array_elements(dados) x where x ? 'id'
    on conflict (id) do nothing;

  when 'livres' then
    insert into public.belasis_horarios_livres (profissional_id, data, slots, atualizado_em)
    values (split_part(v_base, ':', 2)::int, split_part(v_base, ':', 3)::date, dados, now())
    on conflict (profissional_id, data) do update set slots = excluded.slots, atualizado_em = now();

  when 'clientes' then
    insert into public.belasis_clientes as c (id, primeiro_nome, telefones, aniversario, ativo, atualizado_em)
    select (x->>'id')::int,
           initcap(split_part(btrim(coalesce(x->>'nickname', x->>'name', '')), ' ', 1)),
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

-- Inicia uma sincronização completa (somente leitura).
create or replace function public.belasis_iniciar_sync(p_dias_passado integer default 120, p_dias_futuro integer default 45)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  hoje date := (now() at time zone 'America/Maceio')::date;
  sufixo text := to_char(now(), 'YYYYMMDDHH24MI');
begin
  -- chaves com sufixo para permitir novas rodadas
  perform public.belasis_enfileirar('servicos:1#' || sufixo, '/inventory/services', '{"limit":100,"page":1}');
  perform public.belasis_enfileirar('profissionais:1#' || sufixo, '/employees', '{"limit":100,"page":1,"active":true}');
  perform public.belasis_enfileirar('clientes:1#' || sufixo, '/clients', '{"limit":100,"page":1}');
  perform public.belasis_enfileirar('agenda:1#' || sufixo, '/schedule_groups',
    jsonb_build_object('limit', 100, 'page', 1, 'start_date', hoje - p_dias_passado, 'end_date', hoje + p_dias_futuro));
  return jsonb_build_object('ok', true, 'rodada', sufixo,
    'aviso', 'Requisições enfileiradas. O pg_cron chama a Edge Function belasis-sync a cada minuto (até 15 por vez).');
end;
$$;

-- Log de cada GET feito pela Edge Function (sem conteúdo).
create or replace function public.belasis_log_get(p_caminho text, p_status integer, p_ms integer, p_erro text default null)
returns void
language sql
set search_path = ''
as $$
  insert into public.belasis_chamadas (metodo, rota, origem, modo, permitido, status_http, duracao_ms, erro)
  values ('GET', public.belasis_rota(p_caminho), 'sync',
          coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado'), true, p_status, p_ms, left(p_erro, 500));
$$;

-- pg_cron → Edge Function, só quando há fila e o Belasis não está desligado.
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

select cron.schedule('belasis-sync', '* * * * *', 'select public.belasis_disparar_sync()');

do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('checar_segredo_interno','belasis_enfileirar','belasis_proximos',
              'belasis_tel','belasis_registrar_resposta','belasis_iniciar_sync','belasis_log_get','belasis_disparar_sync')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;
