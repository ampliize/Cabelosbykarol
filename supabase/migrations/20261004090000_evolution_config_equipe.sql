-- =====================================================================
-- 008 · Configuração da Evolution API + equipe ignorada nas duas direções
-- (mensagens que o bot envia ao responsável voltam pelo webhook como
-- from_me; não podem virar "humano assumiu" numa conversa com a equipe)
-- Aplicado como: evolution_config + equipe_ambas_direcoes
-- =====================================================================
insert into public.config_bot (chave, valor, descricao) values
  ('evolution_base_url',  'null', 'URL base da Evolution API, sem barra no final (ex.: https://evo.seudominio.com)'),
  ('evolution_instancia', 'null', 'Nome da instância da Evolution conectada ao número')
on conflict (chave) do nothing;
-- registrar_mensagem_entrada: ver migration aplicada (troca
-- "not p_from_me and exists equipe" por "exists equipe").

-- URLs de produção dos webhooks n8n (workflows CBK · WA Retomada e CBK · Equipe Notificar).
update public.config_bot set valor = to_jsonb('https://n8n-n8n.dgwpoe.easypanel.host/webhook/cbk-retomada-4m8x2p'::text)
 where chave = 'n8n_webhook_retomada_url';
update public.config_bot set valor = to_jsonb('https://n8n-n8n.dgwpoe.easypanel.host/webhook/cbk-notificar-9t2v6w'::text)
 where chave = 'n8n_webhook_notificacao_url';
