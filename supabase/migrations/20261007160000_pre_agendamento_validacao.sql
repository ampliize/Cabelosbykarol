-- Pré-agendamento conforme o cliente: o agente só pré-agenda dentro do horário
-- de funcionamento; a equipe valida e lança no Belasis como NÃO CONFIRMADO.
create or replace function public.criar_pre_agendamento(
  p_conversa_id         uuid,
  p_servico             text,
  p_data                date,
  p_hora_inicio         time,
  p_profissional        text    default null,
  p_servico_id          integer default null,
  p_profissional_id     integer default null,
  p_hora_fim            time    default null,
  p_confirmacao_cliente text    default null,
  p_observacao          text    default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conv  public.conversas;
  v_id    bigint;
  v_dur   integer;
  v_fim   time := p_hora_fim;
  v_res   text;
  v_fuso  text := coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_quando timestamptz := (p_data + p_hora_inicio) at time zone v_fuso;
begin
  if v_quando < now() then
    return jsonb_build_object('ok', false, 'erro', 'data_no_passado',
      'orientacao', 'Esse dia/horário já passou. Pergunte outra data.');
  end if;
  if not public.salao_aberto(v_quando) then
    return jsonb_build_object('ok', false, 'erro', 'fora_do_horario',
      'orientacao', 'O salão funciona de terça a sábado, das 9h às 18h. Peça outro dia/horário.',
      'horario_funcionamento', public.cfg('horario_funcionamento'));
  end if;

  select * into v_conv from public.conversas where id = p_conversa_id;
  if v_fim is null and p_servico_id is not null then
    select duracao_min into v_dur from public.belasis_servicos where id = p_servico_id;
    if v_dur is not null then
      v_fim := p_hora_inicio + make_interval(mins => v_dur);
    end if;
  end if;

  insert into public.pre_agendamentos
    (conversa_id, belasis_cliente_id, servico_id, servico, profissional_id, profissional,
     data, hora_inicio, hora_fim, confirmacao_cliente, observacao)
  values
    (p_conversa_id, v_conv.belasis_cliente_id, p_servico_id, p_servico, p_profissional_id, p_profissional,
     p_data, p_hora_inicio, v_fim, p_confirmacao_cliente, p_observacao)
  returning id into v_id;

  v_res := format('Pedido: %s%s — %s às %s%s',
                  p_servico,
                  coalesce(' com ' || p_profissional, ''),
                  to_char(p_data, 'DD/MM (TMDy)'),
                  to_char(p_hora_inicio, 'HH24:MI'),
                  coalesce(' até ' || to_char(v_fim, 'HH24:MI'), ''))
           || coalesce(E'\nObs.: ' || p_observacao, '')
           || E'\nConferir a agenda, lançar no Belasis como NÃO CONFIRMADO e confirmar com a cliente pelo WhatsApp.';

  perform public.encaminhar_para_responsavel('pre_agendamento', p_conversa_id,
                                              'Pré-agendamento para validar', v_res, p_confirmacao_cliente);

  return jsonb_build_object('ok', true, 'pre_agendamento_id', v_id, 'hora_fim', v_fim);
end;
$$;

revoke all on function public.criar_pre_agendamento(uuid, text, date, time, text, integer, integer, time, text, text) from public, anon, authenticated;
grant execute on function public.criar_pre_agendamento(uuid, text, date, time, text, integer, integer, time, text, text) to service_role;
