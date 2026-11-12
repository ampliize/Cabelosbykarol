-- Redesenho 12/11 (conversas reais): o agente olhava pouco a agenda da cliente no Belasis.
-- * agenda_atual_cliente: agenda futura da cliente (Belasis + pré-agendamentos que ainda vão sair),
--   entregue ao agente ANTES de qualquer resposta
-- * agendar_whatsapp: não cria um segundo horário do mesmo serviço no mesmo dia, nem um horário que
--   bate com outro dela (devolve ja_tem_agendamento / conflito_com_outro_horario)
-- * lembretes do Belasis "Passando para lembrar que temos um encontro marcado" eram lidos como equipe
--   (pausavam a IA): agora são mensagem automática

create or replace function public.agenda_atual_cliente(p_conversa_id uuid)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  select jsonb_build_object(
    'sincronizado_em', to_char((select max(atualizado_em) from public.belasis_agendamentos) at time zone 'America/Maceio', 'DD/MM HH24:MI'),
    'agendamentos', coalesce((
      select jsonb_agg(x order by x->>'data', x->>'inicio') from (
        select jsonb_build_object(
                 'belasis_id', a.id, 'data', a.data, 'dia', public.data_curta_pt(a.data),
                 'inicio', public.hora_curta(min((it->>'inicio')::time)),
                 'situacao', case a.status when 'confirmed' then 'confirmado' when 'unconfirmed' then 'aguardando confirmação da equipe'
                                           when 'waiting' then 'cliente no salão' else a.status end,
                 'servicos', jsonb_agg(jsonb_build_object(
                   'servico', coalesce(s.descricao, 'serviço ' || (it->>'servico_id')),
                   'profissional', public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome),
                   'inicio', public.hora_curta((it->>'inicio')::time), 'fim', public.hora_curta((it->>'fim')::time))
                   order by it->>'inicio')) x
          from public.belasis_agendamentos a
          cross join lateral jsonb_array_elements(a.itens) it
          left join public.belasis_servicos s on s.id = (it->>'servico_id')::int
          left join public.belasis_profissionais p on p.id = (it->>'profissional_id')::int
         where a.cliente_id in (select public.belasis_clientes_da_conversa(p_conversa_id))
           and a.data >= (now() at time zone 'America/Maceio')::date
           and a.status not in ('disconfirm', 'removido')
         group by a.id, a.data, a.status) q), '[]'::jsonb),
    'pedidos_pelo_whatsapp_ainda_nao_lancados', coalesce((
      select jsonb_agg(jsonb_build_object('data', pa.data, 'dia', public.data_curta_pt(pa.data), 'inicio', public.hora_curta(pa.hora_inicio),
               'servico', pa.servico, 'profissional', pa.profissional) order by pa.data, pa.hora_inicio)
        from public.pre_agendamentos pa
       where pa.conversa_id = p_conversa_id and pa.estado <> 'cancelado' and pa.belasis_agendamento_id is null
         and pa.data >= (now() at time zone 'America/Maceio')::date), '[]'::jsonb));
$function$;

-- trava de duplicidade no agendar (antes de qualquer outra checagem de vaga)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.agendar_whatsapp(uuid,text,date,time,text,text,text,boolean,text,date,boolean,boolean)'::regprocedure);
  if position('ja_tem_agendamento' in d) > 0 then return; end if;
  d := replace(d, $x$  select profissional_id into v_unica from public.belasis_servico_regras where servico_id = v_serv and quem = 'unica';
$x$, $x$  select profissional_id into v_unica from public.belasis_servico_regras where servico_id = v_serv and quem = 'unica';

  -- a cliente já tem esse serviço nesse dia, ou outro horário dela que bate com este: não cria outro
  if not p_remarcar then
    select x.* into r from (
      select a.data, (it->>'inicio')::time ini, (it->>'fim')::time fim, (it->>'servico_id')::int sid,
             (select descricao from public.belasis_servicos where id = (it->>'servico_id')::int) servico
        from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
       where a.cliente_id in (select public.belasis_clientes_da_conversa(p_conversa_id))
         and a.data = p_data and a.status not in ('disconfirm', 'removido')
      union all
      select pa.data, pa.hora_inicio, coalesce(pa.hora_fim, pa.hora_inicio + interval '1 hour'), pa.servico_id, pa.servico
        from public.pre_agendamentos pa
       where pa.conversa_id = p_conversa_id and pa.data = p_data and pa.estado <> 'cancelado'
         and pa.belasis_agendamento_id is null) x
     where x.sid = v_serv
        or (x.ini < (p_hora + make_interval(mins => v_dur))::time and x.fim > p_hora)
     order by (x.sid = v_serv) desc limit 1;
    if r.data is not null then
      return jsonb_build_object('ok', false,
        'erro', case when r.sid = v_serv then 'ja_tem_agendamento' else 'conflito_com_outro_horario' end,
        'ja_marcado', jsonb_build_object('servico', r.servico, 'dia', public.data_curta_pt(r.data), 'hora', public.hora_curta(r.ini)),
        'orientacao', case when r.sid = v_serv
          then 'Ela JÁ tem esse serviço marcado nesse dia. Não crie outro. Lembre o horário que ela tem e pergunte se quer manter ou trocar (se trocar, chame agendar com remarcar=true).'
          else 'Esse horário bate com outro serviço que ela já tem nesse dia. Não crie em cima. Lembre o que ela já tem e ofereça um horário logo depois (complemento=true, hora = fim do que já tem) ou outro horário.' end);
    end if;
  end if;
$x$);
  if position('ja_tem_agendamento' in d) = 0 then raise exception 'agendar_whatsapp: trecho não encontrado'; end if;
  execute d;
end $$;

-- lembrete do Belasis que era lido como "equipe"
update public.config_bot
   set valor = valor || '["passando para lembrar que\\s*temos um encontro marcado", "seu hor[aá]rio est[aá] reservado"]'::jsonb
 where chave = 'padroes_mensagens_automaticas'
   and not valor ? 'passando para lembrar que\s*temos um encontro marcado';

-- n8n (12/11), aplicado direto nos fluxos:
-- * CBK · WA Entrada: "Transcrever áudio" usava a credencial antiga da OpenAI (chave inválida) → credencial
--   "api cabelos"; o áudio é buscado na Evolution (getBase64FromMediaMessage) antes da transcrição
-- * CBK · Agente Core: "Carregar contexto" traz perfil + agenda_atual_cliente + id da última mensagem da
--   cliente; "Registrar execução" descarta a resposta se chegou mensagem nova da cliente durante o
--   processamento (evita duas respostas para lotes seguidos); prompt v3 (docs/15-PROMPT-AGENTE-V3.md)
