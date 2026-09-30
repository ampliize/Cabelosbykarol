-- =====================================================================
-- 002 · Funções (RPC chamadas pelo n8n)
-- Todas com search_path vazio e execução restrita ao service_role.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Utilitários
-- ---------------------------------------------------------------------

-- Normaliza telefone BR para E.164 sem "+": 55 + DDD + 9 dígitos (celular)
-- Aceita "5511987654321", "(11) 98765-4321", "551187654321" (sem 9º dígito),
-- JID "5511987654321@s.whatsapp.net" ou "5511987654321:12@s.whatsapp.net".
-- Retorna NULL para número não brasileiro ou inválido.
create or replace function public.normalizar_telefone(p text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  d text;
begin
  d := regexp_replace(split_part(split_part(coalesce(p, ''), '@', 1), ':', 1), '\D', '', 'g');
  if length(d) in (10, 11) then
    d := '55' || d;
  end if;
  if left(d, 2) <> '55' or length(d) not in (12, 13) then
    return null;
  end if;
  -- celular antigo sem o 9º dígito (primeiro dígito do número entre 6 e 9)
  if length(d) = 12 and substr(d, 5, 1) in ('6', '7', '8', '9') then
    d := left(d, 4) || '9' || substr(d, 5);
  end if;
  return d;
end;
$$;

create or replace function public.cfg(p_chave text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select valor from public.config_bot where chave = p_chave;
$$;

create or replace function public.tg_atualizado_em()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger conversas_atualizado_em before update on public.conversas
  for each row execute function public.tg_atualizado_em();
create trigger config_bot_atualizado_em before update on public.config_bot
  for each row execute function public.tg_atualizado_em();

-- ---------------------------------------------------------------------
-- Limitador de vazão (janela fixa de 1 minuto — igual à do Belasis)
-- ---------------------------------------------------------------------
create or replace function public.reservar_cota(p_recurso text, p_limite integer)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_janela timestamptz := date_trunc('minute', clock_timestamp());
  v_usadas integer;
begin
  insert into public.rate_limit as r (recurso, janela, chamadas)
  values (p_recurso, v_janela, 1)
  on conflict (recurso, janela) do update set chamadas = r.chamadas + 1
  returning chamadas into v_usadas;

  if v_usadas <= p_limite then
    return jsonb_build_object('permitido', true, 'usadas', v_usadas, 'limite', p_limite, 'aguardar_ms', 0);
  end if;

  return jsonb_build_object(
    'permitido', false, 'usadas', v_usadas, 'limite', p_limite,
    'aguardar_ms', ceil(extract(epoch from (v_janela + interval '1 minute' - clock_timestamp())) * 1000)::int + 500
  );
end;
$$;

-- Atalho para o Belasis (limite configurável, padrão 25 de 30/min)
create or replace function public.reservar_chamada_belasis()
returns jsonb
language sql
set search_path = ''
as $$
  select public.reservar_cota('belasis', coalesce((public.cfg('belasis_limite_por_minuto'))::int, 25));
$$;

-- Chamar quando o Belasis devolver 429: esgota a janela atual
create or replace function public.bloquear_cota(p_recurso text)
returns void
language sql
set search_path = ''
as $$
  insert into public.rate_limit as r (recurso, janela, chamadas)
  values (p_recurso, date_trunc('minute', clock_timestamp()), 100000)
  on conflict (recurso, janela) do update set chamadas = 100000;
$$;

-- ---------------------------------------------------------------------
-- Cache do Belasis
-- ---------------------------------------------------------------------
create or replace function public.cache_get(p_chave text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select valor from public.cache_belasis where chave = p_chave and expira_em > now();
$$;

create or replace function public.cache_set(p_chave text, p_valor jsonb, p_ttl_segundos integer)
returns void
language sql
set search_path = ''
as $$
  insert into public.cache_belasis (chave, valor, expira_em)
  values (p_chave, p_valor, now() + make_interval(secs => p_ttl_segundos))
  on conflict (chave) do update
    set valor = excluded.valor, expira_em = excluded.expira_em, criado_em = now();
$$;

-- ---------------------------------------------------------------------
-- Entrada de mensagem (chamada pelo WA · Entrada para TODO webhook)
-- Faz: normaliza telefone, ignora equipe, upsert da conversa, dedupe,
-- detecta eco do bot / humano assumindo / mensagens automáticas,
-- aplica kill switch, modo piloto, opt-out e pausa.
-- Retorno.acao: 'processar' | 'humano' | 'ignorar'
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

  -- Mensagem enviada PELO número do salão
  if p_from_me then
    -- eco de algo que o próprio bot enviou (webhook chega antes/depois do registro de saída)
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

    -- mensagens automáticas (ex.: lembretes da extensão Belasis) não contam como humano
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

    -- comando da equipe para devolver a conversa ao bot
    if v_texto ~* '^/bot$' then
      update public.conversas set status = 'bot', pausado_ate = null, bot_desativado = false
       where id = v_conv.id;
      update public.handoffs set resolvido_em = now()
       where conversa_id = v_conv.id and resolvido_em is null;
      return jsonb_build_object('acao', 'ignorar', 'motivo', 'bot_reativado', 'conversa_id', v_conv.id);
    end if;

    -- humano respondeu pelo celular/WhatsApp Web: bot silencia por N horas
    update public.conversas
       set status = 'humano_assumiu',
           pausado_ate = now() + make_interval(hours => coalesce((public.cfg('pausa_humano_horas'))::int, 4))
     where id = v_conv.id;
    update public.handoffs set atendido_por = coalesce(atendido_por, 'whatsapp')
     where conversa_id = v_conv.id and resolvido_em is null;
    return jsonb_build_object('acao', 'ignorar', 'motivo', 'humano_respondeu', 'conversa_id', v_conv.id);
  end if;

  -- Mensagem da cliente
  update public.conversas set ultima_msg_cliente_em = now()
   where id = v_conv.id
   returning * into v_conv;

  -- pausa expirada => volta para o bot
  if v_conv.status <> 'bot' and v_conv.pausado_ate is not null and v_conv.pausado_ate <= now() then
    update public.conversas set status = 'bot', pausado_ate = null
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
    v_resultado := jsonb_build_object('acao', 'humano', 'motivo', v_conv.status);
  else
    return jsonb_build_object(
      'acao', 'processar',
      'conversa_id', v_conv.id,
      'mensagem_id', v_msg_id,
      'telefone', v_tel,
      'nome', coalesce(v_conv.nome, v_conv.push_name),
      'belasis_cliente_id', v_conv.belasis_cliente_id,
      'janela_segundos', coalesce((public.cfg('janela_agrupamento_segundos'))::int, 8)
    );
  end if;

  -- não será processada pelo bot: tira do buffer para não entrar num lote futuro
  update public.mensagens set processada_em = now() where id = v_msg_id;
  return v_resultado || jsonb_build_object('conversa_id', v_conv.id, 'mensagem_id', v_msg_id);
end;
$$;

-- ---------------------------------------------------------------------
-- Agrupamento: após esperar a janela, só a execução da ÚLTIMA mensagem
-- pendente processa o lote inteiro. As demais recebem processar=false.
-- ---------------------------------------------------------------------
create or replace function public.coletar_lote(p_conversa_id uuid, p_mensagem_id bigint)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_status text;
  v_ultima bigint;
  v_lote   jsonb;
begin
  select status into v_status from public.conversas where id = p_conversa_id for update;

  if v_status is distinct from 'bot' then
    update public.mensagens set processada_em = now()
     where conversa_id = p_conversa_id and direcao = 'in' and processada_em is null;
    return jsonb_build_object('processar', false, 'motivo', coalesce(v_status, 'conversa_inexistente'));
  end if;

  select max(id) into v_ultima
    from public.mensagens
   where conversa_id = p_conversa_id and direcao = 'in' and processada_em is null;

  if v_ultima is null or v_ultima <> p_mensagem_id then
    return jsonb_build_object('processar', false, 'motivo', 'lote_de_outra_execucao');
  end if;

  with lote as (
    update public.mensagens
       set processada_em = now()
     where conversa_id = p_conversa_id and direcao = 'in' and processada_em is null
    returning id, tipo, texto, media_url
  )
  select jsonb_build_object(
           'processar', true,
           'quantidade', count(*),
           'ids', jsonb_agg(id order by id),
           'texto', string_agg(
              case tipo
                when 'text'  then texto
                when 'audio' then '[áudio] ' || coalesce(texto, '(sem transcrição)')
                when 'image' then '[imagem]' || coalesce(' ' || texto, '')
                else '[' || tipo || ']' || coalesce(' ' || texto, '')
              end, E'\n' order by id),
           'imagens', coalesce(jsonb_agg(media_url order by id)
                               filter (where tipo = 'image' and media_url is not null), '[]'::jsonb)
         )
    into v_lote
    from lote;

  return v_lote;
end;
$$;

-- ---------------------------------------------------------------------
-- Envio: checa regras anti-ban antes de cada mensagem do bot
-- R1 (janela 24 h), R4 (intervalo por conversa + limite global), kill switch
-- ---------------------------------------------------------------------
create or replace function public.verificar_envio(p_conversa_id uuid)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conv        public.conversas;
  v_ultimo_out  timestamptz;
  v_intervalo   integer := coalesce((public.cfg('envio_intervalo_min_ms'))::int, 3000);
  v_espera      integer := 0;
  v_cota        jsonb;
begin
  select * into v_conv from public.conversas where id = p_conversa_id;
  if v_conv.id is null then
    return jsonb_build_object('permitido', false, 'motivo', 'conversa_inexistente');
  end if;

  if not coalesce((public.cfg('bot_ativo'))::boolean, false) then
    return jsonb_build_object('permitido', false, 'motivo', 'bot_desligado');
  end if;

  -- humano na conversa: só permite a mensagem de despedida logo após o handoff
  if v_conv.status <> 'bot' and not (
       v_conv.status = 'aguardando_humano'
       and exists (select 1 from public.handoffs h
                    where h.conversa_id = p_conversa_id and h.criado_em > now() - interval '2 minutes')
     ) then
    return jsonb_build_object('permitido', false, 'motivo', 'humano_na_conversa');
  end if;

  if v_conv.ultima_msg_cliente_em is null or v_conv.ultima_msg_cliente_em < now() - interval '24 hours' then
    return jsonb_build_object('permitido', false, 'motivo', 'fora_da_janela_24h');
  end if;

  select max(criado_em) into v_ultimo_out
    from public.mensagens
   where conversa_id = p_conversa_id and direcao = 'out' and autor = 'bot';
  if v_ultimo_out is not null then
    v_espera := greatest(0, v_intervalo - (extract(epoch from (clock_timestamp() - v_ultimo_out)) * 1000)::int);
  end if;

  v_cota := public.reservar_cota('whatsapp_envio', coalesce((public.cfg('envio_limite_por_minuto'))::int, 20));
  if not (v_cota->>'permitido')::boolean then
    return jsonb_build_object('permitido', false, 'motivo', 'limite_global', 'aguardar_ms', v_cota->'aguardar_ms');
  end if;

  return jsonb_build_object('permitido', true, 'aguardar_ms', v_espera);
end;
$$;

create or replace function public.registrar_mensagem_saida(
  p_conversa_id uuid,
  p_texto       text,
  p_message_id  text default null,
  p_autor       text default 'bot',
  p_tipo        text default 'text'
)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.mensagens (conversa_id, message_id, direcao, autor, tipo, texto, processada_em)
  values (p_conversa_id, p_message_id, 'out', p_autor, p_tipo, p_texto, now())
  on conflict (message_id) do nothing
  returning id into v_id;
  update public.conversas set ultima_msg_em = now() where id = p_conversa_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Handoff para humano
-- ---------------------------------------------------------------------
create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
begin
  insert into public.handoffs (conversa_id, motivo, resumo)
  values (p_conversa_id, p_motivo, p_resumo)
  returning id into v_handoff_id;

  update public.conversas
     set status = 'aguardando_humano',
         pausado_ate = now() + make_interval(hours => coalesce((public.cfg('timeout_aguardando_humano_horas'))::int, 12)),
         bot_desativado = bot_desativado or p_motivo = 'opt_out'
   where id = p_conversa_id
   returning * into v_conv;

  return jsonb_build_object(
    'handoff_id', v_handoff_id,
    'telefone', v_conv.telefone,
    'nome', coalesce(v_conv.nome, v_conv.push_name),
    'destinatarios', coalesce((
       select jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone))
         from public.equipe e where e.recebe_handoff and e.ativo), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Escrita no Belasis: idempotência + auditoria
-- ---------------------------------------------------------------------
create or replace function public.reservar_acao_belasis(
  p_idempotency_key     text,
  p_conversa_id         uuid,
  p_acao                text,
  p_request             jsonb,
  p_confirmacao_cliente text
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_id   bigint;
  v_acao public.acoes_belasis;
begin
  insert into public.acoes_belasis (idempotency_key, conversa_id, acao, request, confirmacao_cliente)
  values (p_idempotency_key, p_conversa_id, p_acao, p_request, p_confirmacao_cliente)
  on conflict (idempotency_key) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('executar', true, 'acao_id', v_id);
  end if;

  select * into v_acao from public.acoes_belasis where idempotency_key = p_idempotency_key for update;

  if v_acao.estado = 'erro' then
    update public.acoes_belasis
       set estado = 'pendente', erro = null, request = p_request,
           confirmacao_cliente = p_confirmacao_cliente, concluido_em = null
     where id = v_acao.id;
    return jsonb_build_object('executar', true, 'acao_id', v_acao.id, 'nova_tentativa', true);
  end if;

  -- já feita (sucesso) ou em andamento (pendente): não repetir
  return jsonb_build_object(
    'executar', false, 'acao_id', v_acao.id, 'estado', v_acao.estado,
    'belasis_agendamento_id', v_acao.belasis_agendamento_id, 'response', v_acao.response
  );
end;
$$;

create or replace function public.concluir_acao_belasis(
  p_acao_id                bigint,
  p_sucesso                boolean,
  p_http_status            integer,
  p_response               jsonb,
  p_belasis_agendamento_id integer default null,
  p_belasis_cliente_id     integer default null,
  p_erro                   text    default null
)
returns void
language sql
set search_path = ''
as $$
  update public.acoes_belasis
     set estado = case when p_sucesso then 'sucesso' else 'erro' end,
         http_status = p_http_status,
         response = p_response,
         belasis_agendamento_id = coalesce(p_belasis_agendamento_id, belasis_agendamento_id),
         belasis_cliente_id = coalesce(p_belasis_cliente_id, belasis_cliente_id),
         erro = p_erro,
         concluido_em = now()
   where id = p_acao_id;
$$;

-- ---------------------------------------------------------------------
-- Base de conhecimento: índice de busca (português, sem acento) + busca
-- ---------------------------------------------------------------------
create or replace function public.tg_kb_busca()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.busca :=
       setweight(to_tsvector('portuguese', extensions.unaccent(coalesce(new.pergunta, ''))), 'A')
    || setweight(to_tsvector('portuguese', extensions.unaccent(array_to_string(new.palavras_chave, ' '))), 'A')
    || setweight(to_tsvector('portuguese', extensions.unaccent(coalesce(new.resposta, ''))), 'B');
  new.atualizado_em := now();
  return new;
end;
$$;

create trigger kb_itens_busca before insert or update on public.kb_itens
  for each row execute function public.tg_kb_busca();

-- Busca por qualquer termo (OR) com ranking. Sem resultado e com categoria
-- informada, devolve os itens daquela categoria.
create or replace function public.buscar_kb(
  p_consulta  text,
  p_categoria text    default null,
  p_limite    integer default 5
)
returns table (id bigint, categoria text, pergunta text, resposta text, relevancia real)
language plpgsql
stable
set search_path = ''
as $$
declare
  v_q tsquery;
begin
  v_q := nullif(replace(plainto_tsquery('portuguese', extensions.unaccent(coalesce(p_consulta, '')))::text, '&', '|'), '')::tsquery;

  return query
    select k.id, k.categoria, k.pergunta, k.resposta, ts_rank(k.busca, v_q) as relevancia
      from public.kb_itens k
     where k.aprovado and k.ativo
       and v_q is not null and k.busca @@ v_q
       and (p_categoria is null or k.categoria = p_categoria)
     order by relevancia desc
     limit p_limite;

  if not found and p_categoria is not null then
    return query
      select k.id, k.categoria, k.pergunta, k.resposta, 0::real
        from public.kb_itens k
       where k.aprovado and k.ativo and k.categoria = p_categoria
       order by k.atualizado_em desc
       limit p_limite;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Retenção (LGPD) — agendada via pg_cron em 003
-- ---------------------------------------------------------------------
create or replace function public.limpar_dados_antigos()
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_dias      integer := coalesce((public.cfg('retencao_mensagens_dias'))::int, 180);
  v_limite    timestamptz := now() - make_interval(days => v_dias);
  v_mensagens integer;
  v_execucoes integer;
  v_memoria   integer;
  v_cache     integer;
  v_rate      integer;
begin
  delete from public.mensagens where criado_em < v_limite;
  get diagnostics v_mensagens = row_count;

  delete from public.execucoes_agente where criado_em < v_limite;
  get diagnostics v_execucoes = row_count;

  delete from public.n8n_chat_histories h
   where not exists (select 1 from public.conversas c
                      where c.id::text = h.session_id and c.ultima_msg_em >= v_limite);
  get diagnostics v_memoria = row_count;

  delete from public.cache_belasis where expira_em < now() - interval '1 hour';
  get diagnostics v_cache = row_count;

  delete from public.rate_limit where janela < now() - interval '1 day';
  get diagnostics v_rate = row_count;

  return jsonb_build_object('mensagens', v_mensagens, 'execucoes', v_execucoes,
                            'memoria', v_memoria, 'cache', v_cache, 'rate_limit', v_rate);
end;
$$;

-- ---------------------------------------------------------------------
-- Permissões: nada para anon/authenticated
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('normalizar_telefone','cfg','tg_atualizado_em','reservar_cota',
                         'reservar_chamada_belasis','bloquear_cota','cache_get','cache_set',
                         'registrar_mensagem_entrada','coletar_lote','verificar_envio',
                         'registrar_mensagem_saida','iniciar_handoff','reservar_acao_belasis',
                         'concluir_acao_belasis','tg_kb_busca','buscar_kb','limpar_dados_antigos')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end;
$$;
