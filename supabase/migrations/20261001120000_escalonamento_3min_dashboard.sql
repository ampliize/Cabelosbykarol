-- =====================================================================
-- 007 · Retorno em 3 min, encaminhamento ao responsável e dados do dashboard
--
-- 1. Tempos: se nenhum humano responder em 3 min, o agente volta a atender.
-- 2. Encaminhamento: quando o agente não sabe o que fazer, há problema no
--    atendimento ou erro de sistema, a mensagem vai para o responsável
--    (fila `notificacoes_equipe` → n8n envia no WhatsApp do responsável).
--    Se ninguém responder a uma transferência em 3 min, o agente volta e o
--    responsável recebe um alerta "sem resposta".
-- 3. Dashboard: `dashboard_dados(dias)` devolve tudo em um JSON, liberado
--    só para e-mails cadastrados em `painel_usuarios`.
-- (Sem DELETE/DROP: o apply via MCP fica preso esperando confirmação.)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Tempos de 3 minutos
-- ---------------------------------------------------------------------
update public.config_bot set valor = '3' where chave in (
  'devolver_ao_bot_apos_minutos', 'minutos_espera_handoff', 'minutos_tolerancia_resposta_humana');
update public.config_bot set valor = '["opt_out"]',
       descricao = 'Motivos de transferencia em que o agente NAO volta sozinho (so com /bot). Reclamacao volta em 3 min e o responsavel e alertado.'
 where chave = 'motivos_sem_retorno_automatico';

insert into public.config_bot (chave, valor, descricao) values
  ('n8n_webhook_notificacao_url', 'null',
   'URL do webhook Equipe Notificar no n8n (envia o encaminhamento no WhatsApp do responsavel). Segredo no Vault: n8n_webhook_retomada_secret'),
  ('notificacao_max_tentativas', '3', 'Tentativas de reenvio de um encaminhamento ao responsavel')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- 2. Encaminhamento ao responsável
-- ---------------------------------------------------------------------
alter table public.equipe add column if not exists recebe_alertas_sistema boolean not null default false;

create table public.notificacoes_equipe (
  id                 bigint generated always as identity primary key,
  conversa_id        uuid references public.conversas(id) on delete set null,
  handoff_id         bigint references public.handoffs(id) on delete set null,
  tipo               text not null check (tipo in (
                       'transferencia',        -- agente passou a conversa para humano
                       'duvida_agente',        -- agente não sabe responder, pede orientação
                       'problema_atendimento', -- algo deu errado com a cliente (ex.: agendamento falhou)
                       'erro_sistema',         -- Belasis/LLM/WhatsApp/n8n com erro
                       'sem_resposta_humana')),-- ninguém respondeu a transferência a tempo
  motivo             text,
  resumo             text,
  mensagem_cliente   text,
  telefone_cliente   text,
  nome_cliente       text,
  destinatarios      jsonb not null default '[]'::jsonb,
  estado             text not null default 'pendente' check (estado in ('pendente','enviada','erro')),
  tentativas         integer not null default 0,
  ultimo_request_id  bigint,
  erro               text,
  criado_em          timestamptz not null default now(),
  enviado_em         timestamptz
);
create index notificacoes_equipe_pendentes_idx on public.notificacoes_equipe (criado_em) where estado <> 'enviada';
create index notificacoes_equipe_conversa_idx on public.notificacoes_equipe (conversa_id, criado_em desc);
alter table public.notificacoes_equipe enable row level security;
revoke all on public.notificacoes_equipe from anon, authenticated;

-- Dispara o envio no n8n (pg_net). Sem URL/segredo configurados, fica pendente.
create or replace function public.disparar_notificacao(p_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_url    text := public.cfg('n8n_webhook_notificacao_url') #>> '{}';
  v_secret text;
  v_n      public.notificacoes_equipe;
  v_req    bigint;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'n8n_webhook_retomada_secret' limit 1;
  if v_url is null or v_secret is null then
    return false;
  end if;

  select * into v_n from public.notificacoes_equipe where id = p_id;
  select net.http_post(
           url     := v_url,
           body    := jsonb_build_object(
                        'evento', 'notificacao_equipe',
                        'notificacao_id', v_n.id,
                        'tipo', v_n.tipo,
                        'motivo', v_n.motivo,
                        'resumo', v_n.resumo,
                        'mensagem_cliente', v_n.mensagem_cliente,
                        'telefone_cliente', v_n.telefone_cliente,
                        'nome_cliente', v_n.nome_cliente,
                        'conversa_id', v_n.conversa_id,
                        'destinatarios', v_n.destinatarios),
           headers := jsonb_build_object('Content-Type', 'application/json', 'x-cbk-secret', v_secret),
           timeout_milliseconds := 5000
         ) into v_req;

  update public.notificacoes_equipe
     set tentativas = tentativas + 1, ultimo_request_id = v_req
   where id = p_id;
  return true;
end;
$$;

-- Ponto único para encaminhar algo ao responsável.
create or replace function public.encaminhar_para_responsavel(
  p_tipo             text,
  p_conversa_id      uuid    default null,
  p_motivo           text    default null,
  p_resumo           text    default null,
  p_mensagem_cliente text    default null,
  p_handoff_id       bigint  default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conv  public.conversas;
  v_dest  jsonb;
  v_id    bigint;
  v_msg   text := p_mensagem_cliente;
begin
  if p_conversa_id is not null then
    select * into v_conv from public.conversas where id = p_conversa_id;
    if v_msg is null then
      select string_agg(texto, E'\n' order by id) into v_msg
        from (select id, texto from public.mensagens
               where conversa_id = p_conversa_id and autor = 'cliente' and texto is not null
               order by id desc limit 3) t;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone)), '[]'::jsonb)
    into v_dest
    from public.equipe e
   where e.ativo
     and case when p_tipo = 'erro_sistema' then e.recebe_alertas_sistema or e.recebe_handoff
              else e.recebe_handoff end;

  insert into public.notificacoes_equipe
    (conversa_id, handoff_id, tipo, motivo, resumo, mensagem_cliente, telefone_cliente, nome_cliente, destinatarios)
  values
    (p_conversa_id, p_handoff_id, p_tipo, p_motivo, p_resumo, v_msg, v_conv.telefone,
     coalesce(v_conv.nome, v_conv.push_name), v_dest)
  returning id into v_id;

  perform public.disparar_notificacao(v_id);

  return jsonb_build_object('notificacao_id', v_id, 'destinatarios', v_dest,
                            'sem_destinatario', jsonb_array_length(v_dest) = 0);
end;
$$;

create or replace function public.marcar_notificacao(p_id bigint, p_sucesso boolean, p_erro text default null)
returns void
language sql
set search_path = ''
as $$
  update public.notificacoes_equipe
     set estado = case when p_sucesso then 'enviada' else 'erro' end,
         enviado_em = case when p_sucesso then now() else enviado_em end,
         erro = p_erro
   where id = p_id;
$$;

-- Reenvio (cron): pendentes/erro há mais de 1 min, até o máximo de tentativas
create or replace function public.reenviar_notificacoes()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n   record;
  v_q integer := 0;
begin
  for n in
    select id from public.notificacoes_equipe
     where estado <> 'enviada'
       and tentativas < coalesce((public.cfg('notificacao_max_tentativas'))::int, 3)
       and criado_em < now() - interval '1 minute'
       and criado_em > now() - interval '1 hour'
     order by id
     for update skip locked
  loop
    if public.disparar_notificacao(n.id) then
      v_q := v_q + 1;
    end if;
  end loop;
  return v_q;
end;
$$;

-- Transferência agora também encaminha ao responsável
create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
  v_sem_volta  boolean := coalesce(public.cfg('motivos_sem_retorno_automatico'), '["opt_out"]'::jsonb) ? p_motivo;
  v_notif      jsonb;
begin
  insert into public.handoffs (conversa_id, motivo, resumo)
  values (p_conversa_id, p_motivo, p_resumo)
  returning id into v_handoff_id;

  update public.conversas
     set status = 'aguardando_humano',
         pausado_ate = case when v_sem_volta then null
                            else now() + make_interval(mins => coalesce((public.cfg('minutos_espera_handoff'))::int, 3)) end,
         bot_desativado = bot_desativado or p_motivo = 'opt_out'
   where id = p_conversa_id
   returning * into v_conv;

  v_notif := public.encaminhar_para_responsavel(
               case when p_motivo = 'incerteza' then 'duvida_agente'
                    when p_motivo = 'erro_sistema' then 'erro_sistema'
                    else 'transferencia' end,
               p_conversa_id, p_motivo, p_resumo, null, v_handoff_id);

  update public.handoffs set notificado_em = now() where id = v_handoff_id;

  return jsonb_build_object(
    'handoff_id', v_handoff_id,
    'telefone', v_conv.telefone,
    'nome', coalesce(v_conv.nome, v_conv.push_name),
    'bot_volta_em', v_conv.pausado_ate,
    'retorno_automatico', not v_sem_volta,
    'notificacao_id', v_notif->'notificacao_id',
    'destinatarios', v_notif->'destinatarios'
  );
end;
$$;

-- Devolução: se a transferência ficou sem resposta, alerta o responsável
create or replace function public.devolver_conversas_ao_bot()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c            record;
  v_origem     text;
  v_reab       jsonb;
  v_url        text := public.cfg('n8n_webhook_retomada_url') #>> '{}';
  v_secret     text;
  v_req        bigint;
  v_bot_ativo  boolean := coalesce((public.cfg('bot_ativo'))::boolean, false);
  v_piloto     boolean := coalesce((public.cfg('modo_piloto'))::boolean, false);
  v_whitelist  jsonb   := coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb);
  v_handoff    public.handoffs;
  v_devolvidas integer := 0;
  v_acionadas  integer := 0;
begin
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'n8n_webhook_retomada_secret' limit 1;

  for c in
    select *
      from public.conversas
     where status in ('humano_assumiu', 'aguardando_humano')
       and pausado_ate is not null and pausado_ate <= now()
       and not bot_desativado
     order by pausado_ate
     for update skip locked
  loop
    v_origem := case c.status when 'humano_assumiu' then 'humano_inativo' else 'handoff_sem_resposta' end;

    if v_origem = 'handoff_sem_resposta' then
      select * into v_handoff from public.handoffs
       where conversa_id = c.id and resolvido_em is null order by id desc limit 1;
      perform public.encaminhar_para_responsavel(
        'sem_resposta_humana', c.id, v_handoff.motivo,
        'Ninguem respondeu a transferencia em ' || coalesce((public.cfg('minutos_espera_handoff'))::text, '3')
          || ' min. O agente voltou a atender. Resumo original: ' || coalesce(v_handoff.resumo, '-'),
        null, v_handoff.id);
    end if;

    update public.conversas set status = 'bot', pausado_ate = null where id = c.id;
    update public.handoffs
       set resolvido_em = now(), atendido_por = coalesce(atendido_por, 'retorno_automatico')
     where conversa_id = c.id and resolvido_em is null;
    v_devolvidas := v_devolvidas + 1;

    v_reab := public.reabrir_mensagens_pendentes(c.id);
    v_req  := null;

    if (v_reab->>'pendentes')::int > 0
       and v_bot_ativo
       and (not v_piloto or v_whitelist ? c.telefone)
       and c.ultima_msg_cliente_em > now() - interval '24 hours'
       and v_url is not null and v_secret is not null then
      select net.http_post(
               url     := v_url,
               body    := jsonb_build_object(
                            'evento', 'retomada',
                            'origem', v_origem,
                            'conversa_id', c.id,
                            'mensagem_id', (v_reab->>'ultima_mensagem_id')::bigint,
                            'telefone', c.telefone,
                            'nome', coalesce(c.nome, c.push_name),
                            'belasis_cliente_id', c.belasis_cliente_id,
                            'pendentes', (v_reab->>'pendentes')::int),
               headers := jsonb_build_object('Content-Type', 'application/json', 'x-cbk-secret', v_secret),
               timeout_milliseconds := 5000
             ) into v_req;
      v_acionadas := v_acionadas + 1;
    end if;

    insert into public.retomadas_bot (conversa_id, origem, mensagens_pendentes, ultima_mensagem_id, webhook_request_id)
    values (c.id, v_origem, (v_reab->>'pendentes')::int, (v_reab->>'ultima_mensagem_id')::bigint, v_req);
  end loop;

  perform public.reenviar_notificacoes();

  return jsonb_build_object('devolvidas', v_devolvidas, 'acionadas', v_acionadas);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Dashboard
-- ---------------------------------------------------------------------
create table public.painel_usuarios (
  email     text primary key,
  nome      text,
  criado_em timestamptz not null default now()
);
alter table public.painel_usuarios enable row level security;
revoke all on public.painel_usuarios from anon, authenticated;

create or replace function public.dashboard_dados(p_dias integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_ini  timestamptz;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_role  text := coalesce(auth.jwt() ->> 'role', '');
  v_res  jsonb;
begin
  -- security definer: current_user é sempre o dono; quem chamou é a role do JWT
  -- (PostgREST) ou a sessão direta no banco (SQL editor / conexão postgres).
  if v_role <> 'service_role' and session_user not in ('postgres', 'supabase_admin')
     and not exists (select 1 from public.painel_usuarios u where lower(u.email) = v_email) then
    raise exception 'acesso_negado' using errcode = '42501';
  end if;

  p_dias := least(greatest(coalesce(p_dias, 7), 1), 90);
  v_ini  := date_trunc('day', now() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo'
            - make_interval(days => p_dias - 1);

  with
  conv_periodo as (
    select distinct m.conversa_id
      from public.mensagens m
     where m.criado_em >= v_ini and m.autor = 'cliente'
  ),
  conv_humano as (
    select distinct conversa_id from public.mensagens
     where criado_em >= v_ini and autor = 'humano'
    union
    select distinct conversa_id from public.handoffs where criado_em >= v_ini
  ),
  resp_humana as (
    select h.id, h.motivo, h.criado_em,
           (select min(m.criado_em) from public.mensagens m
             where m.conversa_id = h.conversa_id and m.autor = 'humano' and m.criado_em > h.criado_em) as respondido_em
      from public.handoffs h
     where h.criado_em >= v_ini
  ),
  kpis as (
    select
      (select count(*) from conv_periodo)                                              as conversas,
      (select count(*) from conv_periodo where conversa_id not in (select conversa_id from conv_humano)) as resolvidas_pelo_agente,
      (select count(*) from public.mensagens where criado_em >= v_ini and autor = 'cliente') as msgs_clientes,
      (select count(*) from public.mensagens where criado_em >= v_ini and autor = 'bot')     as msgs_agente,
      (select count(*) from public.mensagens where criado_em >= v_ini and autor = 'humano')  as msgs_equipe,
      (select count(*) from public.handoffs where criado_em >= v_ini)                        as transferencias,
      (select count(*) from resp_humana where respondido_em is not null
          and respondido_em - criado_em <= make_interval(mins => coalesce((public.cfg('minutos_espera_handoff'))::int, 3))) as transf_respondidas_no_prazo,
      (select round(extract(epoch from percentile_cont(0.5) within group (order by respondido_em - criado_em)) / 60.0, 1)
         from resp_humana where respondido_em is not null)                                   as tempo_resposta_humana_mediana_min,
      (select count(*) from public.retomadas_bot where criado_em >= v_ini)                   as retomadas,
      (select count(*) from public.notificacoes_equipe where criado_em >= v_ini)             as encaminhamentos,
      (select count(*) from public.notificacoes_equipe where criado_em >= v_ini and tipo = 'erro_sistema') as erros_sistema,
      (select count(*) from public.notificacoes_equipe where criado_em >= v_ini and estado <> 'enviada' and tentativas > 0) as encaminhamentos_falhos,
      (select count(*) from public.acoes_belasis where criado_em >= v_ini and acao = 'criar_agendamento'    and estado = 'sucesso') as agendamentos,
      (select count(*) from public.acoes_belasis where criado_em >= v_ini and acao = 'remarcar_agendamento' and estado = 'sucesso') as remarcacoes,
      (select count(*) from public.acoes_belasis where criado_em >= v_ini and acao = 'cancelar_agendamento' and estado = 'sucesso') as cancelamentos,
      (select count(*) from public.acoes_belasis where criado_em >= v_ini and estado = 'erro')  as erros_belasis,
      (select round(percentile_cont(0.5) within group (order by latencia_ms)) from public.execucoes_agente where criado_em >= v_ini) as latencia_agente_p50_ms,
      (select round(percentile_cont(0.95) within group (order by latencia_ms)) from public.execucoes_agente where criado_em >= v_ini) as latencia_agente_p95_ms,
      (select coalesce(sum(tokens_in), 0) from public.execucoes_agente where criado_em >= v_ini)  as tokens_in,
      (select coalesce(sum(tokens_out), 0) from public.execucoes_agente where criado_em >= v_ini) as tokens_out,
      (select count(*) from public.vw_alertas_escrita_sem_confirmacao where criado_em >= v_ini)  as escritas_sem_confirmacao
  ),
  dias as (
    select generate_series((v_ini at time zone 'America/Sao_Paulo')::date,
                           (now() at time zone 'America/Sao_Paulo')::date, interval '1 day')::date as dia
  ),
  serie as (
    select d.dia,
      (select count(distinct conversa_id) from public.mensagens m
        where m.autor = 'cliente' and (m.criado_em at time zone 'America/Sao_Paulo')::date = d.dia) as conversas,
      (select count(*) from public.handoffs h where (h.criado_em at time zone 'America/Sao_Paulo')::date = d.dia) as transferencias,
      (select count(*) from public.acoes_belasis a where a.acao = 'criar_agendamento' and a.estado = 'sucesso'
          and (a.criado_em at time zone 'America/Sao_Paulo')::date = d.dia) as agendamentos
      from dias d
  ),
  motivos as (
    select motivo, count(*) as total from public.handoffs where criado_em >= v_ini group by motivo
  ),
  tipos_encaminhamento as (
    select tipo, count(*) as total from public.notificacoes_equipe where criado_em >= v_ini group by tipo
  ),
  mapa_calor as (
    select extract(isodow from criado_em at time zone 'America/Sao_Paulo')::int as dia_semana,
           extract(hour  from criado_em at time zone 'America/Sao_Paulo')::int as hora,
           count(*) as total
      from public.mensagens where criado_em >= v_ini and autor = 'cliente'
     group by 1, 2
  ),
  agora as (
    select c.id, coalesce(c.nome, c.push_name) as nome, c.telefone, c.status, c.pausado_ate,
           c.ultima_msg_cliente_em,
           (select h.motivo from public.handoffs h where h.conversa_id = c.id and h.resolvido_em is null order by h.id desc limit 1) as motivo
      from public.conversas c
     where c.status <> 'bot'
     order by c.ultima_msg_cliente_em desc nulls last
     limit 50
  ),
  ultimos_enc as (
    select n.id, n.criado_em, n.tipo, n.motivo, n.resumo, n.mensagem_cliente, n.nome_cliente, n.telefone_cliente, n.estado
      from public.notificacoes_equipe n
     where n.criado_em >= v_ini
     order by n.id desc
     limit 30
  )
  select jsonb_build_object(
    'gerado_em', now(),
    'periodo_dias', p_dias,
    'inicio', v_ini,
    'bot_ativo', coalesce((public.cfg('bot_ativo'))::boolean, false),
    'modo_piloto', coalesce((public.cfg('modo_piloto'))::boolean, false),
    'minutos_retorno', coalesce((public.cfg('devolver_ao_bot_apos_minutos'))::int, 3),
    'kpis', (select to_jsonb(k) from kpis k),
    'serie_diaria', (select coalesce(jsonb_agg(to_jsonb(s) order by s.dia), '[]'::jsonb) from serie s),
    'motivos_transferencia', (select coalesce(jsonb_agg(to_jsonb(m) order by m.total desc), '[]'::jsonb) from motivos m),
    'tipos_encaminhamento', (select coalesce(jsonb_agg(to_jsonb(t) order by t.total desc), '[]'::jsonb) from tipos_encaminhamento t),
    'mapa_calor', (select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from mapa_calor h),
    'conversas_com_humano', (select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) from agora a),
    'ultimos_encaminhamentos', (select coalesce(jsonb_agg(to_jsonb(u)), '[]'::jsonb) from ultimos_enc u)
  ) into v_res;

  return v_res;
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
revoke all on function public.disparar_notificacao(bigint) from public, anon, authenticated;
revoke all on function public.encaminhar_para_responsavel(text, uuid, text, text, text, bigint) from public, anon, authenticated;
revoke all on function public.marcar_notificacao(bigint, boolean, text) from public, anon, authenticated;
revoke all on function public.reenviar_notificacoes() from public, anon, authenticated;
revoke all on function public.iniciar_handoff(uuid, text, text) from public, anon, authenticated;
revoke all on function public.devolver_conversas_ao_bot() from public, anon, authenticated;
revoke all on function public.dashboard_dados(integer) from public, anon;
grant execute on function public.disparar_notificacao(bigint) to service_role;
grant execute on function public.encaminhar_para_responsavel(text, uuid, text, text, text, bigint) to service_role;
grant execute on function public.marcar_notificacao(bigint, boolean, text) to service_role;
grant execute on function public.reenviar_notificacoes() to service_role;
grant execute on function public.iniciar_handoff(uuid, text, text) to service_role;
grant execute on function public.devolver_conversas_ao_bot() to service_role;
grant execute on function public.dashboard_dados(integer) to authenticated, service_role;
