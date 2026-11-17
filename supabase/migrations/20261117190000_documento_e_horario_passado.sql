-- Conversa real de 17/11 (Isa): às 11:35 a cliente mandou "Comprovante_....pdf" e o agente respondeu
-- "obrigada, te esperamos às 9h" — o horário já tinha passado e comprovante é assunto da equipe.
-- * triagem_documento: se a cliente mandou documento (PDF etc.), a conversa vai para a equipe sem passar
--   pelo agente (transferência silenciosa, motivo fora_escopo, com o nome do arquivo no aviso).
--   Usado pelo n8n (CBK · Agente Core > Carregar contexto > "Precisa responder?").
-- * agenda_atual_cliente: cada horário traz ja_passou (hoje e já começou) — o agente nunca diz
--   "te esperamos" para um horário que já passou.

create or replace function public.triagem_documento(p_conversa_id uuid)
returns boolean
language plpgsql
set search_path to ''
as $function$
declare
  m        record;
  v_docs   text := null;
begin
  for m in select autor, tipo, texto from public.mensagens where conversa_id = p_conversa_id order by id desc limit 15 loop
    exit when m.autor <> 'cliente';
    if m.tipo = 'document' then v_docs := concat_ws(', ', v_docs, coalesce(nullif(m.texto, ''), 'arquivo')); end if;
  end loop;
  if v_docs is null then return false; end if;
  -- já está com a equipe: só não chama o agente
  if exists (select 1 from public.handoffs where conversa_id = p_conversa_id and resolvido_em is null) then return true; end if;
  perform public.iniciar_handoff(p_conversa_id, 'fora_escopo',
    'A cliente enviou documento (' || left(v_docs, 200) || '). Pode ser comprovante de pagamento: conferir e responder.');
  return true;
end;
$function$;

-- agenda da cliente com "ja_passou"
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agenda_atual_cliente(uuid)'::regprocedure);
  if position('ja_passou' in d) > 0 then return; end if;
  d := replace(d, $x$'inicio', public.hora_curta(min((it->>'inicio')::time)),$x$,
                  $x$'inicio', public.hora_curta(min((it->>'inicio')::time)),
                 'ja_passou', a.data = (now() at time zone 'America/Maceio')::date and min((it->>'inicio')::time) <= (now() at time zone 'America/Maceio')::time,$x$);
  d := replace(d, $x$'inicio', public.hora_curta(pa.hora_inicio),$x$,
                  $x$'inicio', public.hora_curta(pa.hora_inicio),
               'ja_passou', pa.data = (now() at time zone 'America/Maceio')::date and pa.hora_inicio <= (now() at time zone 'America/Maceio')::time,$x$);
  if (length(d) - length(replace(d, 'ja_passou', ''))) / length('ja_passou') <> 2 then
    raise exception 'agenda_atual_cliente: trecho não encontrado';
  end if;
  execute d;
end $$;

-- n8n (17/11): Carregar contexto chama triagem_documento; "Precisa responder?" não chama o agente quando
-- so_encerramento ou documento_transferido. Prompt v3.4 (docs/15-PROMPT-AGENTE-V3.md): ja_passou e
-- comprovante/pagamento → transferir (fora_escopo).
