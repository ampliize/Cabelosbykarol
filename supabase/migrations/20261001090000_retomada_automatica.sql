-- =====================================================================
-- 005 · Devolução automática da conversa ao agente por inatividade humana
--
-- Regra: o bot fica pausado enquanto a equipe conversa. Cada mensagem da
-- equipe reinicia o timer de `devolver_ao_bot_apos_minutos`. Se a cliente
-- escreve durante a pausa, a equipe ganha no mínimo
-- `minutos_tolerancia_resposta_humana` para responder. Vencido o timer:
--   1. a conversa volta para 'bot';
--   2. mensagens da cliente que ficaram sem resposta são reabertas;
--   3. o n8n é acionado (pg_net → webhook) para o agente responder.
-- Um job pg_cron roda a cada minuto. Se o webhook não estiver configurado,
-- a conversa volta ao bot e as pendentes entram junto na próxima mensagem.
-- =====================================================================

-- requer pg_net (20261001085900_habilitar_pg_net.sql)

-- ---------------------------------------------------------------------
-- Configuração
-- ---------------------------------------------------------------------
-- chaves antigas ficam só marcadas como obsoletas (não são mais lidas)
update public.config_bot
   set descricao = 'OBSOLETO (substituido por devolver_ao_bot_apos_minutos / minutos_espera_handoff) - nao e mais lido'
 where chave in ('pausa_humano_horas', 'timeout_aguardando_humano_horas');

insert into public.config_bot (chave, valor, descricao) values
  ('devolver_ao_bot_apos_minutos',        '30',
   'Minutos sem mensagem da equipe para o agente reassumir a conversa (o timer reinicia a cada mensagem da equipe)'),
  ('minutos_tolerancia_resposta_humana',  '5',
   'Quando a cliente escreve com humano na conversa, a equipe tem pelo menos este tempo para responder antes do agente voltar'),
  ('minutos_espera_handoff',              '60',
   'Depois de uma transferência, minutos sem nenhuma resposta da equipe até o agente reassumir'),
  ('motivos_sem_retorno_automatico',      '["reclamacao", "opt_out"]',
   'Motivos de transferência em que o agente NÃO volta sozinho (só com /bot)'),
  ('retomada_max_horas_msg_pendente',     '12',
   'Mensagens da cliente mais antigas que isso não são respondidas na retomada'),
  ('n8n_webhook_retomada_url',            'null',
   'URL do webhook "WA · Retomada" no n8n. O segredo fica no Vault: n8n_webhook_retomada_secret')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- Log das retomadas
-- ---------------------------------------------------------------------
create table public.retomadas_bot (
  id                  bigint generated always as identity primary key,
  conversa_id         uuid not null references public.conversas(id) on delete cascade,
  origem              text not null check (origem in ('humano_inativo','handoff_sem_resposta','lazy')),
  mensagens_pendentes integer not null default 0,
  ultima_mensagem_id  bigint,
  webhook_request_id  bigint,
  criado_em           timestamptz not null default now()
);
create index retomadas_bot_conversa_idx on public.retomadas_bot (conversa_id, criado_em desc);
alter table public.retomadas_bot enable row level security;
revoke all on public.retomadas_bot from anon, authenticated;

-- ---------------------------------------------------------------------
-- Helper: reabre (volta ao buffer) as mensagens da cliente que ficaram
-- sem resposta desde a última mensagem enviada pela equipe ou pelo bot.
-- ---------------------------------------------------------------------
create or replace function public.reabrir_mensagens_pendentes(p_conversa_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_ultimo_out timestamptz;
  v_qtd        integer;
  v_ultima     bigint;
begin
  select max(criado_em) into v_ultimo_out
    from public.mensagens
   where conversa_id = p_conversa_id and direcao = 'out' and autor in ('humano', 'bot');

  with pend as (
    update public.mensagens
       set processada_em = null
     where conversa_id = p_conversa_id
       and direcao = 'in' and autor = 'cliente'
       and criado_em > coalesce(v_ultimo_out, '-infinity'::timestamptz)
       and criado_em > now() - make_interval(hours => coalesce((public.cfg('retomada_max_horas_msg_pendente'))::int, 12))
    returning id
  )
  select count(*), max(id) into v_qtd, v_ultima from pend;

  return jsonb_build_object('pendentes', v_qtd, 'ultima_mensagem_id', v_ultima);
end;
$$;

-- ---------------------------------------------------------------------
-- Contexto recente da conversa (inclui o que a equipe falou) para o
-- prompt do agente — a memória do n8n só tem as falas do próprio bot.
-- ---------------------------------------------------------------------
create or replace function public.contexto_conversa(p_conversa_id uuid, p_limite integer default 20)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'autor', autor, 'tipo', tipo, 'texto', texto,
           'em', to_char(criado_em at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI'))
         order by id), '[]'::jsonb)
    from (select id, autor, tipo, texto, criado_em
            from public.mensagens
           where conversa_id = p_conversa_id and autor <> 'sistema'
           order by id desc
           limit p_limite) t;
$$;

-- ---------------------------------------------------------------------
-- Job do pg_cron (a cada minuto): devolve conversas vencidas ao bot e
-- aciona o n8n quando há mensagem da cliente esperando resposta.
-- ---------------------------------------------------------------------
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

  return jsonb_build_object('devolvidas', v_devolvidas, 'acionadas', v_acionadas);
end;
$$;

-- ---------------------------------------------------------------------
-- registrar_mensagem_entrada: timer de inatividade em minutos
-- ---------------------------------------------------------------------
create or replace function public.registrar_mensagem_entrada(
  p_message_id text,
  p_telefone   text,
  p_from_me    boolean,
  p_tipo       text  default 'text',
  p_texto      text  default null,
  p_media_url  text  default null,
  p_push_name  text  default null,
  p_jid        text  default null,
  p_raw        jsonb default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_tel       text := public.normalizar_telefone(p_telefone);
  v_texto     text := btrim(coalesce(p_texto, ''));
  v_tipo      text := case when p_tipo in ('text','audio','image','video','document','sticker',
                                           'reaction','location','contact') then p_tipo else 'outro' end;
  v_conv      public.conversas;
  v_autor     text;
  v_msg_id    bigint;
  v_eco_id    bigint;
  v_padrao    text;
  v_resultado jsonb;
  v_origem    text := 'mensagem';
begin
  if v_tel is null then
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'telefone_invalido');
  end if;

  if not p_from_me and exists (select 1 from public.equipe e where e.telefone = v_tel and e.ativo) then
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'numero_equipe');
  end if;

  insert into public.conversas as c (telefone, whatsapp_jid, push_name, ultima_msg_em)
  values (v_tel, p_jid, case when p_from_me then null else nullif(btrim(p_push_name), '') end, now())
  on conflict (telefone) do update set
    whatsapp_jid  = coalesce(excluded.whatsapp_jid, c.whatsapp_jid),
    push_name     = coalesce(excluded.push_name, c.push_name),
    ultima_msg_em = now()
  returning * into v_conv;

  if p_from_me then
    select m.id into v_eco_id
      from public.mensagens m
     where m.conversa_id = v_conv.id and m.autor = 'bot' and m.direcao = 'out'
       and m.criado_em > now() - interval '2 minutes'
       and btrim(coalesce(m.texto, '')) = v_texto
     order by m.id desc
     limit 1;
    if v_eco_id is not null then
      update public.mensagens set message_id = p_message_id
       where id = v_eco_id and message_id is null
         and not exists (select 1 from public.mensagens x where x.message_id = p_message_id);
      return jsonb_build_object('acao', 'ignorar', 'motivo', 'eco_bot', 'conversa_id', v_conv.id);
    end if;

    select pad into v_padrao
      from jsonb_array_elements_text(coalesce(public.cfg('padroes_mensagens_automaticas'), '[]'::jsonb)) as pad
     where v_texto ~* pad
     limit 1;
    v_autor := case when v_padrao is not null then 'sistema' else 'humano' end;
  else
    v_autor := 'cliente';
  end if;

  insert into public.mensagens (conversa_id, message_id, direcao, autor, tipo, texto, media_url, raw, processada_em)
  values (v_conv.id, p_message_id, case when p_from_me then 'out' else 'in' end, v_autor, v_tipo,
          nullif(v_texto, ''), p_media_url, p_raw, case when p_from_me then now() end)
  on conflict (message_id) do nothing
  returning id into v_msg_id;

  if v_msg_id is null then
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'duplicada', 'conversa_id', v_conv.id);
  end if;

  if p_from_me then
    if v_autor = 'sistema' then
      return jsonb_build_object('acao', 'ignorar', 'motivo', 'mensagem_automatica', 'conversa_id', v_conv.id);
    end if;

    if v_texto ~* '^/bot$' then
      update public.conversas set status = 'bot', pausado_ate = null, bot_desativado = false
       where id = v_conv.id;
      update public.handoffs set resolvido_em = now()
       where conversa_id = v_conv.id and resolvido_em is null;
      return jsonb_build_object('acao', 'ignorar', 'motivo', 'bot_reativado', 'conversa_id', v_conv.id);
    end if;

    -- equipe falou: (re)inicia o timer de inatividade
    update public.conversas
       set status = 'humano_assumiu',
           pausado_ate = now() + make_interval(mins => coalesce((public.cfg('devolver_ao_bot_apos_minutos'))::int, 30))
     where id = v_conv.id;
    update public.handoffs set atendido_por = coalesce(atendido_por, 'whatsapp')
     where conversa_id = v_conv.id and resolvido_em is null;
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'humano_respondeu', 'conversa_id', v_conv.id);
  end if;

  -- Mensagem da cliente
  update public.conversas set ultima_msg_cliente_em = now()
   where id = v_conv.id
   returning * into v_conv;

  -- timer vencido e o cron ainda não passou: devolve aqui mesmo
  if v_conv.status <> 'bot' and v_conv.pausado_ate is not null and v_conv.pausado_ate <= now()
     and not v_conv.bot_desativado then
    update public.conversas set status = 'bot', pausado_ate = null
     where id = v_conv.id
     returning * into v_conv;
    update public.handoffs
       set resolvido_em = now(), atendido_por = coalesce(atendido_por, 'retorno_automatico')
     where conversa_id = v_conv.id and resolvido_em is null;
    perform public.reabrir_mensagens_pendentes(v_conv.id);
    insert into public.retomadas_bot (conversa_id, origem) values (v_conv.id, 'lazy');
    v_origem := 'retomada';
  end if;

  -- humano na conversa: garante tempo mínimo para a equipe responder esta mensagem
  if v_conv.status = 'humano_assumiu' and v_conv.pausado_ate is not null then
    update public.conversas
       set pausado_ate = greatest(pausado_ate,
             now() + make_interval(mins => coalesce((public.cfg('minutos_tolerancia_resposta_humana'))::int, 5)))
     where id = v_conv.id
     returning * into v_conv;
  end if;

  if not coalesce((public.cfg('bot_ativo'))::boolean, false) then
    v_resultado := jsonb_build_object('acao', 'ignorar', 'motivo', 'bot_desligado');
  elsif coalesce((public.cfg('modo_piloto'))::boolean, false)
        and not coalesce(public.cfg('whitelist_piloto'), '[]'::jsonb) ? v_tel then
    v_resultado := jsonb_build_object('acao', 'ignorar', 'motivo', 'fora_do_piloto');
  elsif v_conv.bot_desativado then
    v_resultado := jsonb_build_object('acao', 'humano', 'motivo', 'opt_out');
  elsif v_conv.status <> 'bot' then
    v_resultado := jsonb_build_object('acao', 'humano', 'motivo', v_conv.status,
                                      'bot_volta_em', v_conv.pausado_ate);
  else
    return jsonb_build_object(
      'acao', 'processar',
      'origem', v_origem,
      'conversa_id', v_conv.id,
      'mensagem_id', v_msg_id,
      'telefone', v_tel,
      'nome', coalesce(v_conv.nome, v_conv.push_name),
      'belasis_cliente_id', v_conv.belasis_cliente_id,
      'janela_segundos', coalesce((public.cfg('janela_agrupamento_segundos'))::int, 8)
    );
  end if;

  -- não será processada agora: sai do buffer (a retomada reabre se ficar sem resposta)
  update public.mensagens set processada_em = now() where id = v_msg_id;
  return v_resultado || jsonb_build_object('conversa_id', v_conv.id, 'mensagem_id', v_msg_id);
end;
$$;

-- ---------------------------------------------------------------------
-- iniciar_handoff: espera em minutos; reclamação/opt-out não voltam sozinhos
-- ---------------------------------------------------------------------
create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
  v_sem_volta  boolean := coalesce(public.cfg('motivos_sem_retorno_automatico'), '["reclamacao","opt_out"]'::jsonb) ? p_motivo;
begin
  insert into public.handoffs (conversa_id, motivo, resumo)
  values (p_conversa_id, p_motivo, p_resumo)
  returning id into v_handoff_id;

  update public.conversas
     set status = 'aguardando_humano',
         pausado_ate = case when v_sem_volta then null
                            else now() + make_interval(mins => coalesce((public.cfg('minutos_espera_handoff'))::int, 60)) end,
         bot_desativado = bot_desativado or p_motivo = 'opt_out'
   where id = p_conversa_id
   returning * into v_conv;

  return jsonb_build_object(
    'handoff_id', v_handoff_id,
    'telefone', v_conv.telefone,
    'nome', coalesce(v_conv.nome, v_conv.push_name),
    'bot_volta_em', v_conv.pausado_ate,
    'retorno_automatico', not v_sem_volta,
    'destinatarios', coalesce((
       select jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone))
         from public.equipe e where e.recebe_handoff and e.ativo), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões e agendamento
-- ---------------------------------------------------------------------
revoke all on function public.reabrir_mensagens_pendentes(uuid) from public, anon, authenticated;
revoke all on function public.contexto_conversa(uuid, integer) from public, anon, authenticated;
revoke all on function public.devolver_conversas_ao_bot() from public, anon, authenticated;
revoke all on function public.registrar_mensagem_entrada(text, text, boolean, text, text, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.iniciar_handoff(uuid, text, text) from public, anon, authenticated;
grant execute on function public.reabrir_mensagens_pendentes(uuid) to service_role;
grant execute on function public.contexto_conversa(uuid, integer) to service_role;
grant execute on function public.devolver_conversas_ao_bot() to service_role;
grant execute on function public.registrar_mensagem_entrada(text, text, boolean, text, text, text, text, text, jsonb) to service_role;
grant execute on function public.iniciar_handoff(uuid, text, text) to service_role;

select cron.schedule('cbk-devolver-conversas', '* * * * *', $$select public.devolver_conversas_ao_bot()$$);
