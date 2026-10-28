-- Ajustes antes dos testes com clientes reais (28/10):
-- 1) o agente só PRÉ-agenda: entra no Belasis como NÃO CONFIRMADO (a equipe confirma)
-- 2) intenção de negociação (desconto, preço menor, parcelamento) → transfere e avisa a equipe
-- 3) quando transfere (ou não sabe responder), o agente NÃO escreve nada para a cliente: só avisa a equipe
-- 4) negociação e incerteza não voltam sozinhas para a IA (evita repetir pergunta / responder sem saber)

update public.config_bot set valor = '"unconfirmed"'::jsonb where chave in ('belasis_status_agendamento', 'status_agendamento_bot');
update public.config_bot set valor = '["opt_out", "negociacao", "incerteza"]'::jsonb where chave = 'motivos_sem_retorno_automatico';

create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
  v_sem_volta  boolean := coalesce(public.cfg('motivos_sem_retorno_automatico'), '["opt_out"]'::jsonb) ? p_motivo;
  v_notif      jsonb;
  v_motivo     text := p_motivo;
  v_resumo     text := p_resumo;
begin
  -- negociação é registrada como fora_escopo (motivos do handoff são fixos), com o resumo marcado
  if v_motivo = 'negociacao' then
    v_motivo := 'fora_escopo';
    v_resumo := 'NEGOCIAÇÃO: ' || coalesce(p_resumo, '');
  elsif v_motivo not in ('pedido_cliente', 'reclamacao', 'fora_escopo', 'orcamento_visual', 'erro_sistema', 'incerteza', 'opt_out') then
    v_motivo := 'incerteza';
  end if;

  insert into public.handoffs (conversa_id, motivo, resumo)
  values (p_conversa_id, v_motivo, v_resumo)
  returning id into v_handoff_id;

  update public.conversas
     set status = 'aguardando_humano',
         pausado_ate = case when v_sem_volta then null
                            else now() + make_interval(mins => coalesce((public.cfg('minutos_espera_handoff'))::int, 3)) end,
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
    'bot_volta_em', v_conv.pausado_ate,
    'retorno_automatico', not v_sem_volta,
    'notificacao_id', v_notif->'notificacao_id'
  );
end;
$function$;

-- depois de transferir, nada de "já chamei alguém": a IA fica em silêncio
do $$
declare d text;
begin
  d := pg_get_functiondef('public.verificar_envio(uuid)'::regprocedure);
  if position('h.criado_em > now() - interval ''2 minutes''' in d) > 0 then
    d := replace(d, $x$  if v_conv.status <> 'bot' and not (
       v_conv.status = 'aguardando_humano'
       and exists (select 1 from public.handoffs h
                    where h.conversa_id = p_conversa_id and h.criado_em > now() - interval '2 minutes')
     ) then$x$, $x$  if v_conv.status <> 'bot' then$x$);
    if position('2 minutes' in d) > 0 then raise exception 'verificar_envio: trecho não encontrado'; end if;
    execute d;
  end if;
end $$;

-- confirmação: pré-agendado, a equipe confirma
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  d := replace(d, $x$'orientacao', 'Diga que está agendado (dia, hora e profissional), curto e natural.$x$,
                  $x$'orientacao', 'Diga que deixou o horário pré-agendado (dia, hora e profissional) e que a equipe confirma com ela por aqui, curto e natural. Não diga que está confirmado.$x$);
  d := replace(d, $x$'ok', true, 'agendado', true,$x$, $x$'ok', true, 'pre_agendado', true, 'confirmado', false,$x$);
  if position('pre_agendado' in d) = 0 then raise exception 'agendar_whatsapp: trecho não encontrado'; end if;
  execute d;
end $$;

-- base: desconto/parcelamento agora é negociação (transfere); dúvida sem resposta → transfere em silêncio
update public.kb_itens set resposta = 'ORIENTAÇÃO: é negociação. Use transferir_para_humano (motivo negociacao) e não escreva nada para a cliente.'
 where fonte = 'ampliize' and (pergunta like 'Tem desconto?%' or pergunta = 'Dá para parcelar?');
update public.kb_itens set resposta = 'ORIENTAÇÃO: o horário normal é de terça a sábado, das 9h às 18h. Se ela perguntar de um feriado específico, não responda: transferir_para_humano (incerteza), sem escrever nada.'
 where fonte = 'ampliize' and pergunta = 'Abre em feriado?';
update public.kb_itens set resposta = 'ORIENTAÇÃO: use consultar_servicos com "masculino" e "corte". Se houver, responda e siga o agendamento. Se não houver, não responda: transferir_para_humano (incerteza), sem escrever nada.'
 where fonte = 'ampliize' and pergunta like 'Atendem homem?%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: o salão não informou idade mínima. Não responda: transferir_para_humano (incerteza), sem escrever nada.'
 where fonte = 'ampliize' and pergunta = 'Atendem criança?';
update public.kb_itens set resposta = 'ORIENTAÇÃO: não dê orientação de saúde. Acolha e diga que o teste de mecha/avaliação gratuito existe justamente para isso: a profissional avalia antes de qualquer química. Ofereça agendar o teste.'
 where fonte = 'ampliize' and pergunta like 'Tenho alergia%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: na dúvida, ir com o cabelo limpo e seco, sem creme ou óleo, ajuda; para química, a profissional orienta no teste de mecha. Se ela quiser algo específico que você não sabe, transferir_para_humano (incerteza), sem escrever nada.'
 where fonte = 'ampliize' and pergunta like 'Preciso ir com o cabelo lavado?%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: a durabilidade e o intervalo de manutenção variam com o tipo de cabelo e os cuidados em casa; a profissional orienta isso na avaliação/teste de mecha (gratuitos). Ofereça agendar. Se ela insistir em um número, transferir_para_humano (incerteza), sem escrever nada.'
 where fonte = 'ampliize' and pergunta like 'Quanto tempo dura a selagem%';
