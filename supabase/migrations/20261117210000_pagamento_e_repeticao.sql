-- Conversa real de 17/11 (Chris): a equipe fechava uma venda (R$ 3.800, entrada R$ 1.140 por PIX) e mandou
-- a chave PIX; 5 min depois a cliente mandou áudio, o agente reassumiu, disse "quinta de manhã tudo bem"
-- sem consultar a agenda (a equipe já tinha marcado sexta) e repetiu a mesma mensagem quando ela disse
-- "Mando sim".
-- * triagem_documento passa a cobrir PAGAMENTO: cliente fala de pix/comprovante/sinal/entrada/
--   transferência/depósito, ou a equipe mandou chave pix / pediu sinal nas últimas 6 h → transferência
--   silenciosa (fora_escopo) sem chamar o agente.
-- * resposta_repetida: o n8n não envia uma resposta quase igual (similaridade ≥ 0,6) à última do agente
--   nos últimos 30 min.

create extension if not exists pg_trgm with schema extensions;

create or replace function public.triagem_documento(p_conversa_id uuid)
returns boolean
language plpgsql
set search_path to ''
as $function$
declare
  m        record;
  v_docs   text := null;
  v_lote   text := '';
  v_motivo text := null;
  c_pag    constant text := '(pix|comprovante|\msinal\M|\mentrada\M|transferi|transfer[eê]ncia|dep[oó]sit|chave)';
begin
  for m in select autor, tipo, texto from public.mensagens where conversa_id = p_conversa_id order by id desc limit 15 loop
    exit when m.autor <> 'cliente';
    if m.tipo = 'document' then v_docs := concat_ws(', ', v_docs, coalesce(nullif(m.texto, ''), 'arquivo')); end if;
    v_lote := coalesce(m.texto, '') || ' ' || v_lote;
  end loop;

  if v_docs is not null then
    v_motivo := 'A cliente enviou documento (' || left(v_docs, 200) || '). Pode ser comprovante de pagamento: conferir e responder.';
  elsif lower(v_lote) ~ c_pag then
    v_motivo := 'Assunto de pagamento (pix/sinal/comprovante). A cliente escreveu: "' || left(btrim(v_lote), 220) || '"';
  elsif exists (select 1 from public.mensagens h
                 where h.conversa_id = p_conversa_id and h.autor = 'humano' and h.criado_em > now() - interval '6 hours'
                   and h.criado_em > coalesce((select max(x.resolvido_em) from public.handoffs x where x.conversa_id = p_conversa_id), '-infinity')
                   and lower(coalesce(h.texto, '')) ~ '(pix|chave|comprovante|\msinal\M|\mentrada\M)')
        and btrim(v_lote) <> '' then
    v_motivo := 'A equipe está tratando pagamento com a cliente (pix/sinal). Ela respondeu: "' || left(btrim(v_lote), 220) || '"';
  end if;

  if v_motivo is null then return false; end if;
  if exists (select 1 from public.handoffs where conversa_id = p_conversa_id and resolvido_em is null) then return true; end if;
  perform public.iniciar_handoff(p_conversa_id, 'fora_escopo', v_motivo);
  return true;
end;
$function$;

create or replace function public.resposta_repetida(p_conversa_id uuid, p_texto text)
returns boolean
language sql
stable
set search_path to ''
as $function$
  select coalesce(btrim(p_texto), '') <> '' and exists (
    select 1 from (select texto, criado_em from public.mensagens
                    where conversa_id = p_conversa_id and autor = 'bot' order by id desc limit 1) u
     where u.criado_em > now() - interval '30 minutes'
       and extensions.similarity(lower(u.texto), lower(p_texto)) >= 0.6);
$function$;

-- CAUSA PRINCIPAL do caso Chris: o agente TINHA transferido (negociação, 11:31), a equipe respondeu
-- (pausa de 5 min) e, quando a cliente escreveu depois disso, o retorno "lazy" de registrar_mensagem_entrada
-- devolveu a conversa à IA e encerrou a transferência — ignorando a regra de 14/11. Agora esse caminho
-- também respeita transferência aberta (só volta pelo botão "Devolver ao agente").
do $$
declare d text;
begin
  d := pg_get_functiondef('public.registrar_mensagem_entrada(text,text,boolean,text,text,text,text,text,jsonb)'::regprocedure);
  if position('transferencia_aberta_lazy' in d) > 0 then return; end if;
  d := replace(d, $x$  if v_conv.status <> 'bot' and v_conv.pausado_ate is not null and v_conv.pausado_ate <= now()
     and not v_conv.bot_desativado then$x$,
  $x$  if v_conv.status <> 'bot' and v_conv.pausado_ate is not null and v_conv.pausado_ate <= now()
     and not v_conv.bot_desativado
     -- transferencia_aberta_lazy: conversa transferida pelo agente só volta pelo botão "Devolver ao agente"
     and not exists (select 1 from public.handoffs h where h.conversa_id = v_conv.id and h.resolvido_em is null) then$x$);
  if position('transferencia_aberta_lazy' in d) = 0 then raise exception 'registrar_mensagem_entrada: trecho não encontrado'; end if;
  execute d;
end $$;

-- n8n (17/11): "Registrar execução" calcula repetida (resposta_repetida) e "Tem resposta?" não envia
-- quando repetida.
