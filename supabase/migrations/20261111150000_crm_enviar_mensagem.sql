-- CRM: a equipe responde a cliente pelo painel. O envio sai pelo número do salão (n8n · Equipe Notificar,
-- webhook cbk-crm-enviar) e a conversa pausa a IA na hora (mesma regra de quando a equipe escreve pelo
-- WhatsApp: a IA volta depois de 5 min sem a equipe responder). A mensagem entra no histórico pelo eco
-- da Evolution (registrar_mensagem_entrada, autor humano).

insert into public.config_bot (chave, valor, descricao) values
  ('n8n_webhook_crm_enviar_url', '"https://n8n-n8n.dgwpoe.easypanel.host/webhook/cbk-crm-enviar-5h8r2m"'::jsonb,
   'Webhook do n8n que envia pelo WhatsApp do salão as mensagens escritas no painel')
on conflict (chave) do nothing;

create or replace function public.painel_enviar_mensagem(p_conversa_id uuid, p_texto text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  c        public.conversas;
  v_url    text := public.cfg('n8n_webhook_crm_enviar_url') #>> '{}';
  v_secret text;
  v_texto  text := btrim(coalesce(p_texto, ''));
  v_req    bigint;
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  if v_texto = '' then return jsonb_build_object('ok', false, 'erro', 'Escreva a mensagem.'); end if;
  if length(v_texto) > 4000 then return jsonb_build_object('ok', false, 'erro', 'Mensagem muito longa.'); end if;
  select * into c from public.conversas where id = p_conversa_id;
  if c.id is null then return jsonb_build_object('ok', false, 'erro', 'Conversa não encontrada.'); end if;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'n8n_webhook_retomada_secret' limit 1;
  if v_url is null or v_secret is null then return jsonb_build_object('ok', false, 'erro', 'Envio pelo painel não configurado.'); end if;

  -- a equipe assumiu: a IA não responde em paralelo
  update public.conversas
     set status = 'humano_assumiu',
         pausado_ate = greatest(coalesce(pausado_ate, now()),
                                now() + make_interval(mins => coalesce((public.cfg('devolver_ao_bot_apos_minutos'))::int, 5)))
   where id = c.id;
  update public.handoffs set atendido_por = coalesce(atendido_por, 'painel') where conversa_id = c.id and resolvido_em is null;

  select net.http_post(
           url     := v_url,
           body    := jsonb_build_object('evento', 'crm_enviar', 'conversa_id', c.id, 'telefone', c.telefone, 'texto', v_texto,
                                         'enviado_por', coalesce(auth.jwt() ->> 'email', 'painel')),
           headers := jsonb_build_object('Content-Type', 'application/json', 'x-cbk-secret', v_secret),
           timeout_milliseconds := 10000) into v_req;
  return jsonb_build_object('ok', true, 'request_id', v_req);
end;
$function$;

revoke all on function public.painel_enviar_mensagem(uuid, text) from public, anon;
grant execute on function public.painel_enviar_mensagem(uuid, text) to authenticated;

-- n8n (12/11): CBK · WhatsApp Conexão (webhook cbk-whatsapp-conexao-q4t8z1) — o painel consulta, conecta
-- (QR Code, aponta o webhook do CBK · WA Entrada com base64) e desconecta o WhatsApp na Evolution.
-- O fluxo só atende quem passa em painel_autorizado (token do Supabase do usuário logado).
