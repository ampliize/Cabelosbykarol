-- =====================================================================
-- Belasis em modo seguro: nada toca o sistema do salão sem liberação
-- explícita, em etapas.
--
--   desligado  → nenhuma chamada (padrão)
--   varredura  → só a varredura de diagnóstico (GET), o agente não consulta
--   leitura    → varredura + agente consulta (GET); agendamento vira
--                PRÉ-AGENDAMENTO para a equipe lançar no Belasis
--   escrita    → libera POST/PATCH apenas nas rotas da lista branca
--
-- Toda chamada passa por autorizar_chamada_belasis() (modo + lista branca
-- + limite por minuto) e fica registrada em belasis_chamadas, sem corpo
-- (nada de dado pessoal no log).
-- =====================================================================

insert into public.config_bot (chave, valor, descricao) values
  ('belasis_modo', '"desligado"',
   'desligado | varredura | leitura | escrita — ver migration 20261007090000'),
  ('belasis_base_url', '"https://api.belasis.com.br/api/v1"', 'URL base da API Belasis'),
  ('belasis_escrita_rotas',
   '["POST /clients", "POST /schedule_groups", "PATCH /schedule_groups/{id}/cancel"]',
   'Únicas escritas permitidas no modo escrita (DELETE nunca)')
on conflict (chave) do nothing;

-- Folga maior para o próprio salão/outras integrações usarem a mesma cota (30/min).
update public.config_bot set valor = '20' where chave = 'belasis_limite_por_minuto';

-- ---------------------------------------------------------------------
-- Log de chamadas
-- ---------------------------------------------------------------------
create table public.belasis_chamadas (
  id              bigint generated always as identity primary key,
  metodo          text not null,
  rota            text not null,           -- caminho com ids trocados por {id}
  origem          text not null default 'agente',
  conversa_id     uuid references public.conversas(id) on delete set null,
  modo            text not null,
  permitido       boolean not null,
  motivo_bloqueio text,
  status_http     integer,
  duracao_ms      integer,
  erro            text,
  criado_em       timestamptz not null default now()
);
create index belasis_chamadas_criado_idx on public.belasis_chamadas (criado_em desc);
alter table public.belasis_chamadas enable row level security;

create or replace function public.belasis_rota(p_caminho text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(split_part(coalesce(p_caminho, ''), '?', 1), '/[0-9]+', '/{id}', 'g');
$$;

-- Autoriza (ou não) uma chamada. Espera a virada do minuto se a cota acabou
-- (até 2 vezes). Sempre grava o log e devolve log_id.
create or replace function public.autorizar_chamada_belasis(
  p_metodo      text,
  p_caminho     text,
  p_origem      text default 'agente',
  p_conversa_id uuid default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_metodo text := upper(coalesce(p_metodo, ''));
  v_rota   text := public.belasis_rota(p_caminho);
  v_modo   text := coalesce(public.cfg('belasis_modo') #>> '{}', 'desligado');
  v_limite integer := coalesce((public.cfg('belasis_limite_por_minuto'))::int, 20);
  v_motivo text;
  v_cota   jsonb;
  v_usadas integer;
  v_log    bigint;
begin
  if v_modo not in ('varredura', 'leitura', 'escrita') then
    v_motivo := 'belasis_desligado';
  elsif v_modo = 'varredura' and coalesce(p_origem, '') <> 'varredura' then
    v_motivo := 'modo_varredura_so_permite_varredura';
  elsif v_metodo = 'GET' then
    v_motivo := null;
  elsif v_metodo not in ('POST', 'PATCH') then
    v_motivo := 'metodo_proibido';
  elsif v_modo <> 'escrita' then
    v_motivo := 'escrita_bloqueada_no_modo_' || v_modo;
  elsif not coalesce(public.cfg('belasis_escrita_rotas') ? (v_metodo || ' ' || v_rota), false) then
    v_motivo := 'rota_fora_da_lista_branca';
  end if;

  if v_motivo is null then
    for i in 1..3 loop
      select chamadas into v_usadas from public.rate_limit
       where recurso = 'belasis' and janela = date_trunc('minute', clock_timestamp());
      if coalesce(v_usadas, 0) < v_limite then
        v_cota := public.reservar_cota('belasis', v_limite);
        exit when (v_cota->>'permitido')::boolean;
      end if;
      if i = 3 then
        v_motivo := 'limite_por_minuto';
        exit;
      end if;
      perform pg_sleep(60.3 - extract(second from clock_timestamp())::numeric);
    end loop;
  end if;

  insert into public.belasis_chamadas (metodo, rota, origem, conversa_id, modo, permitido, motivo_bloqueio)
  values (v_metodo, v_rota, coalesce(p_origem, 'agente'), p_conversa_id, v_modo, v_motivo is null, v_motivo)
  returning id into v_log;

  return jsonb_build_object(
    'permitido', v_motivo is null,
    'motivo', v_motivo,
    'modo', v_modo,
    'rota', v_rota,
    'log_id', v_log,
    'base_url', public.cfg('belasis_base_url') #>> '{}',
    'agora', clock_timestamp()
  );
end;
$$;

create or replace function public.registrar_chamada_belasis(
  p_log_id     bigint,
  p_status     integer,
  p_duracao_ms integer default null,
  p_erro       text default null
)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.belasis_chamadas
     set status_http = p_status, duracao_ms = p_duracao_ms, erro = left(p_erro, 500)
   where id = p_log_id;
  if p_status = 429 then
    perform public.bloquear_cota('belasis');
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Catálogo espelhado do Belasis (preenchido pela varredura; só leitura)
-- ---------------------------------------------------------------------
create table public.belasis_servicos (
  id            integer primary key,
  descricao     text not null,
  preco_cents   integer,
  duracao_min   integer,
  ativo         boolean,
  online        boolean,               -- available_to_online_scheduling
  group_id      integer,
  atualizado_em timestamptz not null default now()
);

create table public.belasis_profissionais (
  id            integer primary key,
  nome          text not null,
  ativo         boolean not null default true,
  atualizado_em timestamptz not null default now()
);

create table public.belasis_profissional_servicos (
  profissional_id integer not null references public.belasis_profissionais(id),
  servico_id      integer not null,
  ativo           boolean not null default true,
  atualizado_em   timestamptz not null default now(),
  primary key (profissional_id, servico_id)
);

create table public.belasis_varreduras (
  id           bigint generated always as identity primary key,
  relatorio    jsonb not null,
  criado_em    timestamptz not null default now()
);

alter table public.belasis_servicos              enable row level security;
alter table public.belasis_profissionais         enable row level security;
alter table public.belasis_profissional_servicos enable row level security;
alter table public.belasis_varreduras            enable row level security;

-- Grava o resultado da varredura. Itens que sumiram do Belasis ficam inativos
-- (nada é apagado).
create or replace function public.salvar_varredura_belasis(
  p_relatorio     jsonb,
  p_servicos      jsonb,   -- [{id, description, price_cents, duration, active, available_to_online_scheduling, group_id}]
  p_profissionais jsonb,   -- [{id, name}]
  p_vinculos      jsonb    -- [{profissional_id, servico_id}]
)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.belasis_servicos as s (id, descricao, preco_cents, duracao_min, ativo, online, group_id, atualizado_em)
  select (x->>'id')::int, x->>'description', (x->>'price_cents')::int, (x->>'duration')::int,
         coalesce((x->>'active')::boolean, true), coalesce((x->>'available_to_online_scheduling')::boolean, false),
         (x->>'group_id')::int, now()
    from jsonb_array_elements(coalesce(p_servicos, '[]')) x
   where x ? 'id'
  on conflict (id) do update set
    descricao = excluded.descricao, preco_cents = excluded.preco_cents, duracao_min = excluded.duracao_min,
    ativo = excluded.ativo, online = excluded.online, group_id = excluded.group_id, atualizado_em = now();

  if jsonb_array_length(coalesce(p_servicos, '[]')) > 0 then
    update public.belasis_servicos set ativo = false, atualizado_em = now()
     where ativo and id not in (select (x->>'id')::int from jsonb_array_elements(p_servicos) x);
  end if;

  insert into public.belasis_profissionais as p (id, nome, ativo, atualizado_em)
  select (x->>'id')::int, x->>'name', true, now()
    from jsonb_array_elements(coalesce(p_profissionais, '[]')) x
   where x ? 'id'
  on conflict (id) do update set nome = excluded.nome, ativo = true, atualizado_em = now();

  if jsonb_array_length(coalesce(p_profissionais, '[]')) > 0 then
    update public.belasis_profissionais set ativo = false, atualizado_em = now()
     where ativo and id not in (select (x->>'id')::int from jsonb_array_elements(p_profissionais) x);
  end if;

  if jsonb_array_length(coalesce(p_vinculos, '[]')) > 0 then
    update public.belasis_profissional_servicos set ativo = false, atualizado_em = now() where ativo;
    insert into public.belasis_profissional_servicos as v (profissional_id, servico_id, ativo, atualizado_em)
    select distinct (x->>'profissional_id')::int, (x->>'servico_id')::int, true, now()
      from jsonb_array_elements(p_vinculos) x
     where (x->>'profissional_id')::int in (select id from public.belasis_profissionais)
    on conflict (profissional_id, servico_id) do update set ativo = true, atualizado_em = now();
  end if;

  insert into public.belasis_varreduras (relatorio) values (p_relatorio) returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Pré-agendamentos (modo leitura): o agente nunca escreve no Belasis;
-- a cliente confirma no chat e a equipe lança no sistema.
-- ---------------------------------------------------------------------
create table public.pre_agendamentos (
  id                  bigint generated always as identity primary key,
  conversa_id         uuid references public.conversas(id) on delete set null,
  belasis_cliente_id  integer,
  servico_id          integer,
  servico             text not null,
  profissional_id     integer,
  profissional        text,
  data                date not null,
  hora_inicio         time not null,
  hora_fim            time,
  confirmacao_cliente text,
  observacao          text,
  estado              text not null default 'pendente'
                      check (estado in ('pendente', 'lancado', 'recusado', 'cancelado')),
  criado_em           timestamptz not null default now(),
  atualizado_em       timestamptz not null default now()
);
create index pre_agendamentos_pendentes_idx on public.pre_agendamentos (criado_em) where estado = 'pendente';
alter table public.pre_agendamentos enable row level security;

alter table public.notificacoes_equipe drop constraint notificacoes_equipe_tipo_check;
alter table public.notificacoes_equipe add constraint notificacoes_equipe_tipo_check check (tipo in (
  'transferencia', 'duvida_agente', 'problema_atendimento', 'erro_sistema',
  'sem_resposta_humana', 'pre_agendamento'));

create or replace function public.criar_pre_agendamento(
  p_conversa_id         uuid,
  p_servico             text,
  p_data                date,
  p_hora_inicio         time,
  p_profissional        text    default null,
  p_servico_id          integer default null,
  p_profissional_id     integer default null,
  p_hora_fim            time    default null,
  p_confirmacao_cliente text    default null,
  p_observacao          text    default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conv public.conversas;
  v_id   bigint;
  v_dur  integer;
  v_fim  time := p_hora_fim;
  v_res  text;
begin
  select * into v_conv from public.conversas where id = p_conversa_id;
  if v_fim is null and p_servico_id is not null then
    select duracao_min into v_dur from public.belasis_servicos where id = p_servico_id;
    if v_dur is not null then
      v_fim := p_hora_inicio + make_interval(mins => v_dur);
    end if;
  end if;

  insert into public.pre_agendamentos
    (conversa_id, belasis_cliente_id, servico_id, servico, profissional_id, profissional,
     data, hora_inicio, hora_fim, confirmacao_cliente, observacao)
  values
    (p_conversa_id, v_conv.belasis_cliente_id, p_servico_id, p_servico, p_profissional_id, p_profissional,
     p_data, p_hora_inicio, v_fim, p_confirmacao_cliente, p_observacao)
  returning id into v_id;

  v_res := format('Lançar no Belasis: %s%s — %s às %s%s',
                  p_servico,
                  coalesce(' com ' || p_profissional, ''),
                  to_char(p_data, 'DD/MM (TMDy)'),
                  to_char(p_hora_inicio, 'HH24:MI'),
                  coalesce(' até ' || to_char(v_fim, 'HH24:MI'), ''))
           || coalesce(E'\nObs.: ' || p_observacao, '')
           || E'\nDepois de lançar, confirme para a cliente pelo WhatsApp.';

  perform public.encaminhar_para_responsavel('pre_agendamento', p_conversa_id,
                                              'Cliente confirmou horário', v_res, p_confirmacao_cliente);

  return jsonb_build_object('pre_agendamento_id', v_id, 'hora_fim', v_fim);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões: só o service_role (n8n) executa
-- ---------------------------------------------------------------------
revoke all on public.belasis_chamadas, public.belasis_servicos, public.belasis_profissionais,
              public.belasis_profissional_servicos, public.belasis_varreduras, public.pre_agendamentos
  from anon, authenticated;

do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('belasis_rota', 'autorizar_chamada_belasis', 'registrar_chamada_belasis',
                         'salvar_varredura_belasis', 'criar_pre_agendamento')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end;
$$;
