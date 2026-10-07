-- =====================================================================
-- Convivência com o Belasis no mesmo WhatsApp (sem API)
--
-- Pesquisa (docs/09): o Belasis pode mandar lembretes, pedidos de confirmação,
-- aniversário e campanhas pelo WhatsApp Web do salão (extensão Belasis
-- Booster). O módulo de IA do Belasis NÃO será ativado: quem atende é o
-- nosso agente. Essas mensagens saem do número do salão (fromMe)
-- e não podem pausar o agente como se fosse a equipe. A cliente responde
-- a elas ("confirmo", "não vou conseguir") e o agente precisa entender.
-- =====================================================================

-- 1. Padrões das mensagens automáticas do Belasis (case-insensitive).
--    Revisar com os textos reais configurados no Belasis do salão.
update public.config_bot
   set valor = '[
     "(lembr(ete|ando|ar)|passando (pra|para) (te )?lembrar).{0,120}(hor[aá]rio|agendamento|atendimento|amanh[aã]|hoje)",
     "confirm(e|ar|a[cç][aã]o|ando)( (a )?sua)? (de )?(presen[cç]a|hor[aá]rio|agendamento)",
     "agendamento (foi )?(realizado|criado|registrado|confirmado) (com sucesso )?(para|no dia|em)",
     "responda (com )?(sim|1|confirmo)",
     "feliz anivers[aá]rio",
     "cashback",
     "sentimos (a )?sua falta"
   ]'::jsonb
 where chave = 'padroes_mensagens_automaticas'
   and valor = '[]'::jsonb;

insert into public.config_bot (chave, valor, descricao) values
  ('link_agendamento_online', 'null',
   'Link do agendamento online do Belasis do salão (o agente oferece quando a cliente prefere escolher sozinha)')
on conflict (chave) do nothing;

-- 2. O agente passa a ver as mensagens automáticas no histórico
--    (para entender quando a cliente está respondendo a um lembrete).
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
           where conversa_id = p_conversa_id
           order by id desc
           limit p_limite) t;
$$;

-- 3. Resposta da cliente a lembrete/confirmação: avisa a equipe para atualizar
--    o Belasis (sem pausar o agente). Quando a API for ligada, vira PATCH.
alter table public.notificacoes_equipe drop constraint notificacoes_equipe_tipo_check;
alter table public.notificacoes_equipe add constraint notificacoes_equipe_tipo_check check (tipo in (
  'transferencia', 'duvida_agente', 'problema_atendimento', 'erro_sistema',
  'sem_resposta_humana', 'pre_agendamento', 'retorno_lembrete'));

create or replace function public.registrar_retorno_lembrete(
  p_conversa_id uuid,
  p_resposta    text,      -- confirmou | nao_vai | quer_remarcar
  p_detalhe     text default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_resp  text := lower(coalesce(p_resposta, ''));
  v_acao  text;
begin
  v_acao := case v_resp
    when 'confirmou'     then 'Cliente CONFIRMOU presença → marcar como confirmado no Belasis.'
    when 'nao_vai'       then 'Cliente NÃO vai comparecer → cancelar/liberar o horário no Belasis.'
    when 'quer_remarcar' then 'Cliente quer REMARCAR → o agente está coletando a nova preferência.'
    else null end;
  if v_acao is null then
    return jsonb_build_object('ok', false, 'erro', 'resposta deve ser confirmou, nao_vai ou quer_remarcar');
  end if;

  return jsonb_build_object('ok', true) || public.encaminhar_para_responsavel(
    'retorno_lembrete', p_conversa_id, 'Resposta ao lembrete do Belasis',
    v_acao || coalesce(E'\n' || p_detalhe, ''), null);
end;
$$;

revoke all on function public.registrar_retorno_lembrete(uuid, text, text) from public, anon, authenticated;
grant execute on function public.registrar_retorno_lembrete(uuid, text, text) to service_role;
