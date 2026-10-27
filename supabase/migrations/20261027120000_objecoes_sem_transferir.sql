-- Objeções e dúvidas simples: o agente responde sozinho. Transferência (pausa a IA) só quando a cliente
-- pede uma pessoa, reclama, manda foto para orçamento ou a IA realmente não consegue seguir.
-- Quando falta um dado que o salão ainda não informou, a IA dá uma resposta útil, avisa que confirma
-- e chama perguntar_equipe: a equipe recebe a dúvida no WhatsApp, mas a conversa NÃO é pausada.

-- 27/10, erro no teste: a ferramenta agendar falhou 3x com "invalid input syntax for type boolean: \"\""
-- (o n8n manda "" e o Postgres inferia boolean/date em nullif($8, '')). Corrigido no n8n com $n::text
-- antes do nullif em agendar, consultar_horarios e cancelar_agendamento.

create or replace function public.perguntar_equipe(p_conversa_id uuid, p_pergunta text)
returns jsonb
language plpgsql
set search_path to ''
as $function$
begin
  -- no máximo 1 aviso da mesma conversa a cada 10 min (evita rajada)
  if exists (select 1 from public.notificacoes_equipe
              where conversa_id = p_conversa_id and tipo = 'duvida_agente'
                and criado_em > now() - interval '10 minutes') then
    return jsonb_build_object('ok', true, 'ja_avisada', true,
      'orientacao', 'A equipe já foi avisada há pouco. Siga a conversa normalmente.');
  end if;
  perform public.encaminhar_seguro('duvida_agente', p_conversa_id, 'Dúvida da cliente (IA segue atendendo)',
                                   left(coalesce(p_pergunta, ''), 500));
  return jsonb_build_object('ok', true,
    'orientacao', 'Equipe avisada; a conversa continua com você. Não diga que transferiu nem fale em sistema. Siga ajudando no que puder (ex.: oferecer horário).');
end;
$function$;

-- KB: o que antes mandava transferir_para_humano (incerteza) passa a responder + perguntar_equipe
update public.kb_itens set resposta = 'ORIENTAÇÃO: responda você. Não prometa desconto, mas não feche a porta: "no momento os valores são os da tabela, mas deixa eu ver com a equipe se tem alguma condição especial essa semana". Chame perguntar_equipe e, na mesma resposta, já ofereça o horário (o pagamento é só no dia, sem sinal).'
 where fonte = 'ampliize' and pergunta like 'Tem desconto?%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: responda você: aceitamos cartão, PIX e dinheiro, e o pagamento é no dia. Sobre parcelar, diga que confirma as condições com a equipe (perguntar_equipe) e siga com o agendamento; não transfira.'
 where fonte = 'ampliize' and pergunta = 'Dá para parcelar?';
update public.kb_itens set resposta = 'ORIENTAÇÃO: responda você: o horário normal é de terça a sábado, das 9h às 18h. Para feriado, diga que confirma com a equipe (perguntar_equipe) e já ofereça o dia útil mais próximo (consultar_horarios).'
 where fonte = 'ampliize' and pergunta = 'Abre em feriado?';
update public.kb_itens set resposta = 'ORIENTAÇÃO: use consultar_servicos com "masculino" e "corte". Se houver, responda com preço e ofereça horário. Se não houver, diga que vai confirmar com a equipe (perguntar_equipe) e siga a conversa; não transfira.'
 where fonte = 'ampliize' and pergunta like 'Atendem homem?%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: diga que vai confirmar com a equipe a partir de qual idade e qual serviço (perguntar_equipe) e pergunte a idade e o que ela quer fazer, para já adiantar. Não transfira.'
 where fonte = 'ampliize' and pergunta = 'Atendem criança?';
update public.kb_itens set resposta = 'ORIENTAÇÃO: não dê orientação de saúde. Acolha e diga que, para química, coloração e progressiva, o salão faz antes uma avaliação/teste de mecha gratuito, e que a profissional orienta direitinho no dia considerando a gestação. Ofereça agendar a avaliação; se ela quiser falar com alguém, aí transfira (pedido_cliente).'
 where fonte = 'ampliize' and pergunta like 'Grávida pode%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: não dê orientação de saúde. Acolha e diga que o teste de mecha/avaliação gratuito existe justamente para isso: a profissional avalia antes de qualquer química. Ofereça agendar o teste e avise a equipe (perguntar_equipe) para a profissional saber da alergia.'
 where fonte = 'ampliize' and pergunta like 'Tenho alergia%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: responda você: na dúvida, ir com o cabelo limpo e seco, sem creme ou óleo, ajuda; para química, a profissional confirma no teste de mecha. Diga que confirma com a equipe se o serviço dela tem algum cuidado específico (perguntar_equipe).'
 where fonte = 'ampliize' and pergunta like 'Preciso ir com o cabelo lavado?%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: responda você: a durabilidade e o intervalo de manutenção variam com o tipo de cabelo e os cuidados em casa, e a profissional orienta isso na avaliação/teste de mecha (gratuitos). Ofereça agendar. Se ela insistir em um número, diga que confirma com a profissional (perguntar_equipe). Não transfira.'
 where fonte = 'ampliize' and pergunta like 'Quanto tempo dura a selagem%';
update public.kb_itens set resposta = 'ORIENTAÇÃO: agende uma de cada vez com agendar (no mesmo horário com profissionais diferentes, ou em sequência). A segunda pessoa precisa de nome completo para o cadastro. Só transfira se ela pedir para falar com alguém.'
 where fonte = 'ampliize' and pergunta like 'Quero marcar para mim e outra pessoa%';

-- n8n (CBK · Agente Core, 27/10): nova ferramenta perguntar_equipe
--   select public.perguntar_equipe($1::uuid, $2::text) as resultado
-- e prompt: transferir_para_humano só para pedido de pessoa, reclamação, foto/orçamento ou quando não dá
-- para seguir; nunca falar em "erro" ou "sistema" com a cliente.
