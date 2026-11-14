-- Loop de avisos (12/11): o agente transferia (ex.: orçamento por foto), ninguém respondia em 3 min,
-- devolver_conversas_ao_bot devolvia a conversa à IA com aviso "sem resposta", a IA via a mesma
-- pergunta, transferia de novo... 29 avisos em 49 min numa conversa só.
-- Regra nova: conversa transferida pelo agente (qualquer motivo) fica com a equipe e só volta para a IA
-- quando alguém clica "Devolver ao agente" no CRM. A equipe responder pelo WhatsApp não devolve.
-- (A pausa de 5 min quando a equipe entra numa conversa SEM transferência continua igual.)

update public.config_bot
   set valor = '["pedido_cliente","reclamacao","fora_escopo","orcamento_visual","erro_sistema","incerteza","opt_out","negociacao"]'::jsonb
 where chave = 'motivos_sem_retorno_automatico';

-- 1) transferência nunca tem prazo de volta
create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
  v_notif      jsonb;
  v_motivo     text := p_motivo;
  v_resumo     text := p_resumo;
  v_aberto     public.handoffs;
begin
  if v_motivo = 'negociacao' then
    v_motivo := 'fora_escopo';
    v_resumo := 'NEGOCIAÇÃO: ' || coalesce(p_resumo, '');
  elsif v_motivo is null or v_motivo not in ('pedido_cliente', 'reclamacao', 'fora_escopo', 'orcamento_visual', 'erro_sistema', 'incerteza', 'opt_out') then
    v_motivo := 'incerteza';
  end if;

  -- já existe transferência aberta: não abre outra nem avisa de novo
  select * into v_aberto from public.handoffs where conversa_id = p_conversa_id and resolvido_em is null order by id desc limit 1;
  if v_aberto.id is not null then
    update public.conversas set status = 'aguardando_humano', pausado_ate = null,
           bot_desativado = bot_desativado or v_motivo = 'opt_out'
     where id = p_conversa_id and status = 'bot';
    return jsonb_build_object('handoff_id', v_aberto.id, 'ja_transferida', true, 'retorno_automatico', false,
      'orientacao', 'A equipe já foi avisada desta conversa. NÃO escreva nada para a cliente: responda com texto vazio.');
  end if;

  insert into public.handoffs (conversa_id, motivo, resumo)
  values (p_conversa_id, v_motivo, v_resumo)
  returning id into v_handoff_id;

  update public.conversas
     set status = 'aguardando_humano',
         pausado_ate = null,
         bot_desativado = bot_desativado or v_motivo = 'opt_out'
   where id = p_conversa_id
   returning * into v_conv;

  v_notif := public.encaminhar_para_responsavel(
               case when v_motivo = 'incerteza' then 'duvida_agente'
                    when v_motivo = 'erro_sistema' then 'erro_sistema'
                    else 'transferencia' end,
               p_conversa_id, v_motivo, v_resumo, null, v_handoff_id);

  update public.handoffs set notificado_em = now() where id = v_handoff_id;

  return jsonb_build_object(
    'handoff_id', v_handoff_id,
    'orientacao', 'Equipe avisada. NÃO escreva nada para a cliente: responda com texto vazio.',
    'telefone', v_conv.telefone,
    'nome', coalesce(v_conv.nome, v_conv.push_name),
    'bot_volta_em', null,
    'retorno_automatico', false,
    'notificacao_id', v_notif->'notificacao_id',
    'destinatarios', v_notif->'destinatarios'
  );
end;
$function$;

-- 2) retorno automático só para conversas sem transferência aberta
do $$
declare d text;
begin
  d := pg_get_functiondef('public.devolver_conversas_ao_bot()'::regprocedure);
  if position('transferencia_aberta' in d) > 0 then return; end if;
  d := replace(d, $x$       and not bot_desativado
     order by pausado_ate$x$, $x$       and not bot_desativado
       -- transferencia_aberta: só a equipe devolve (botão "Devolver ao agente" no CRM)
       and not exists (select 1 from public.handoffs h where h.conversa_id = conversas.id and h.resolvido_em is null)
     order by pausado_ate$x$);
  if position('transferencia_aberta' in d) = 0 then raise exception 'devolver_conversas_ao_bot: trecho não encontrado'; end if;
  execute d;
end $$;

-- 3) "Devolver ao agente" no CRM encerra a transferência (sem aviso de "ninguém respondeu")
create or replace function public.painel_assumir(p_id uuid, p_assumir boolean)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  if p_assumir then
    update public.conversas
       set status = 'humano_assumiu',
           pausado_ate = now() + make_interval(hours => coalesce((public.cfg('pausa_humano_horas'))::int, 4))
     where id = p_id;
    update public.handoffs set atendido_por = coalesce(atendido_por, 'painel')
     where conversa_id = p_id and resolvido_em is null;
  else
    update public.handoffs
       set resolvido_em = now(), atendido_por = coalesce(atendido_por, coalesce(auth.jwt() ->> 'email', 'painel'))
     where conversa_id = p_id and resolvido_em is null;
    update public.conversas set status = 'humano_assumiu', pausado_ate = now(), bot_desativado = false
     where id = p_id and status <> 'bot';
    perform public.devolver_conversas_ao_bot();
  end if;
  return (select jsonb_build_object('ok', true, 'status', status, 'pausado_ate', pausado_ate) from public.conversas where id = p_id);
end;
$function$;
