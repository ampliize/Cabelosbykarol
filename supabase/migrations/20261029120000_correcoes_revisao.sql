-- Correções da revisão de código (29/10):
-- a) remarcar/cancelar um serviço de comanda com vários serviços NÃO cancela a comanda inteira:
--    o agente transfere para a equipe ajustar no Belasis
-- b) remarcar antes de a comanda sair: o horário antigo da própria cliente não bloqueia o novo,
--    e só é tirado da comanda depois que o novo deu certo (e só ele: o mais recente daquele serviço)
-- c) cancelar: pega o horário mais próximo entre o que já está no Belasis e o que ainda vai sair
-- d) conciliação volta a casar itens que falharam e a equipe lançou à mão
-- e) motivo desconhecido normalizado para incerteza também não volta sozinho para a IA
-- f) gerentes_notificados = null não quebra as transferências
-- g) janela da comanda menor (3 min, cliente parada há 2 min, no máximo 10 min) para o horário aparecer
--    logo no Belasis
-- h) iniciar_handoff devolve de novo telefone/nome/destinatarios

update public.config_bot set valor = '3'::jsonb where chave = 'comanda_espera_minutos';

create or replace function public.belasis_processar_comandas()
returns integer
language plpgsql
set search_path to ''
as $function$
declare
  g      record;
  v_n    integer := 0;
  v_esp  integer := coalesce((public.cfg('comanda_espera_minutos'))::int, 3);
begin
  for g in
    select p.conversa_id, p.data, min(p.id) lider
      from public.pre_agendamentos p
      join public.conversas c on c.id = p.conversa_id
     where p.escrita_estado = 'aguardando_comanda' and p.estado <> 'cancelado'
     group by p.conversa_id, p.data, c.ultima_msg_cliente_em
    having max(p.criado_em) < now() - make_interval(mins => v_esp)
       and (coalesce(c.ultima_msg_cliente_em, '-infinity') < now() - interval '2 minutes'
            or max(p.criado_em) < now() - interval '10 minutes')
  loop
    update public.pre_agendamentos set comanda_id = g.lider, atualizado_em = now()
     where conversa_id = g.conversa_id and data = g.data
       and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado';
    begin
      perform public.belasis_preparar_escrita(g.lider);
    exception when others then
      perform public.belasis_escrita_falhou(g.lider, 'erro interno: ' || sqlerrm);
    end;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$function$;

-- pré-agendamentos ignorados na checagem (o horário que a própria cliente está remarcando)
create or replace function public.pre_ignorados()
returns bigint[]
language sql
stable
set search_path to ''
as $function$
  select coalesce(string_to_array(nullif(current_setting('cbk.ignorar_pre', true), ''), ',')::bigint[], '{}');
$function$;

create or replace function public.belasis_profissional_livre(p_pid integer, p_data date, p_ini time, p_dur integer)
returns boolean
language sql
stable
set search_path to ''
as $function$
  with h as (select slots from public.belasis_horarios_livres where profissional_id = p_pid and data = p_data),
  g as (select (s->>'hour')::time ini, s->>'label' lbl from h, jsonb_array_elements(h.slots) s),
  passo as (select coalesce(min(b.ini - a.ini), interval '60 minutes') p from g a join g b on b.ini > a.ini),
  pedido as (select p_ini ini, (p_ini + make_interval(mins => greatest(p_dur, 15)))::time fim),
  conflito as (
    select exists (select 1 from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it, pedido
                    where a.data = p_data and a.status not in ('disconfirm', 'removido')
                      and (it->>'profissional_id')::int = p_pid
                      and (it->>'inicio')::time < pedido.fim and (it->>'fim')::time > pedido.ini)
        or exists (select 1 from public.pre_agendamentos pa, pedido
                    where pa.profissional_id = p_pid and pa.data = p_data and pa.estado <> 'cancelado'
                      and pa.id <> all (public.pre_ignorados())
                      and pa.hora_inicio < pedido.fim and coalesce(pa.hora_fim, pa.hora_inicio + interval '1 hour') > pedido.ini
                      and (pa.belasis_agendamento_id is null
                           or not exists (select 1 from public.belasis_agendamentos b where b.id = pa.belasis_agendamento_id))) c
  )
  select case
    when (select c from conflito) then false
    when not exists (select 1 from h) then null
    else exists (select 1 from g, pedido where g.ini <= pedido.ini)
         and (select max(g.ini) + passo.p from g, passo group by passo.p) >= (select fim from pedido)
         and not exists (select 1 from g, passo, pedido
                          where g.ini < pedido.fim and g.ini + passo.p > pedido.ini and g.lbl <> 'available')
  end;
$function$;

create or replace function public.agendar_whatsapp(p_conversa_id uuid, p_servico text, p_data date, p_hora time,
  p_profissional text default null, p_confirmacao text default null, p_observacao text default null,
  p_sem_preferencia boolean default false, p_nome_completo text default null, p_nascimento date default null,
  p_remarcar boolean default false, p_complemento boolean default false)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_fuso  text := coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_quando timestamptz := (p_data + p_hora) at time zone v_fuso;
  v_serv  integer := public.belasis_resolver_servico(p_servico);
  v_dur   integer;
  v_pid   integer;
  v_livre boolean;
  v_nome  text;
  v_res   jsonb;
  v_ant_id integer;
  v_ant_data date;
  v_ant_ini text;
  v_ant_itens integer;
  v_fim   time;
  v_sug   jsonb := '[]';
  v_unica integer;
  v_livres jsonb;
  v_pend  bigint;
  r       record;
  v_prof  text := nullif(btrim(coalesce(p_profissional, '')), '');
begin
  if v_quando < now() then
    return jsonb_build_object('ok', false, 'erro', 'data_no_passado', 'orientacao', 'Esse horário já passou. Pergunte outro.');
  end if;
  if not public.salao_aberto(v_quando) then
    return jsonb_build_object('ok', false, 'erro', 'fora_do_horario',
      'orientacao', 'O salão funciona de terça a sábado, das 9h às 18h. Peça outro dia/horário.');
  end if;
  if v_serv is null then
    return jsonb_build_object('ok', false, 'erro', 'servico_nao_encontrado',
      'orientacao', 'Não achei esse serviço no catálogo. Use consultar_servicos e confirme com a cliente qual é.');
  end if;
  select coalesce(duracao_min, 60) into v_dur from public.belasis_servicos where id = v_serv;
  select profissional_id into v_unica from public.belasis_servico_regras where servico_id = v_serv and quem = 'unica';

  -- remarcar: o horário antigo que ainda não saiu na comanda (o mais recente desse serviço, ou o último pedido)
  -- não bloqueia o novo; só é tirado da comanda se o novo der certo
  if p_remarcar then
    select id into v_pend from public.pre_agendamentos
     where conversa_id = p_conversa_id and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado'
     order by (servico_id = v_serv) desc, id desc limit 1;
    if v_pend is not null then
      perform set_config('cbk.ignorar_pre', v_pend::text, true);
    else
      select x.id, x.data, x.inicio into v_ant_id, v_ant_data, v_ant_ini from public.belasis_proximo_agendamento(p_conversa_id) x;
      select jsonb_array_length(a.itens) into v_ant_itens from public.belasis_agendamentos a where a.id = v_ant_id;
      if coalesce(v_ant_itens, 1) > 1 then
        return jsonb_build_object('ok', false, 'erro', 'comanda_com_varios_servicos',
          'orientacao', 'Esse horário está numa comanda com outros serviços. Não remarque sozinha: use transferir_para_humano (incerteza) com o pedido dela e não escreva nada.');
      end if;
    end if;
  end if;

  if not p_complemento and not public.hora_mencionada(p_conversa_id, p_hora) then
    return jsonb_build_object('ok', false, 'erro', 'hora_nao_informada',
      'orientacao', 'A cliente ainda não escolheu o horário. Pergunte que horário ela prefere (pode usar consultar_horarios e sugerir 2 ou 3). Não escolha por ela.');
  end if;

  -- serviço que só uma profissional faz: não precisa perguntar preferência
  if v_prof is null and v_unica is not null then
    select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_prof from public.belasis_profissionais where id = v_unica and ativo;
  end if;

  if v_prof is null and not p_sem_preferencia and not p_complemento then
    v_livres := public.belasis_livres_no_horario(v_serv, p_data, p_hora);
    if jsonb_array_length(v_livres) = 1 then
      return jsonb_build_object('ok', false, 'erro', 'so_uma_livre', 'profissional_livre', v_livres->>0,
        'orientacao', 'Nesse horário só tem vaga com a ' || (v_livres->>0) || '. Não pergunte preferência: diga que tem horário com ela e pergunte se pode marcar. Se a cliente aceitar, chame agendar com profissional=' || (v_livres->>0) || '.');
    elsif jsonb_array_length(v_livres) = 0 then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Ninguém tem vaga nesse horário. Sugira o próximo horário livre (primeiro de livres_no_dia), sem perguntar preferência.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 30, p_hora) -> 'mais_proximos');
    end if;
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',
      'orientacao', 'Pergunte só "tem preferência de profissional?". Não cite nenhum nome. Se ela não tiver preferência, chame de novo com sem_preferencia=true (o salão segue a profissional da vez).');
  end if;

  if not exists (select 1 from public.belasis_clientes_da_conversa(p_conversa_id)) then
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is null
       and coalesce((select btrim(nome) from public.conversas where id = p_conversa_id), '') !~ '\S+\s+\S+' then
      return jsonb_build_object('ok', false, 'erro', 'precisa_cadastro',
        'orientacao', 'Ela ainda não tem cadastro no salão. Pergunte, numa mensagem só e com leveza, o nome completo e a data de nascimento (pra fazer o cadastro e ela receber a confirmação). Se ela disser que já é cliente, peça o nome completo do cadastro.');
    end if;
    if nullif(btrim(coalesce(p_nome_completo, '')), '') is not null then
      update public.conversas set nome = initcap(btrim(p_nome_completo)), nascimento = coalesce(p_nascimento, nascimento)
       where id = p_conversa_id;
    end if;
  end if;

  if v_prof is not null then
    v_pid := public.belasis_resolver_profissional(v_prof);
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_encontrada',
        'orientacao', 'Não achei essa profissional. Pergunte de novo o nome ou se ela pode ser atendida pela profissional da vez. Não cite nomes.');
    end if;
    if v_pid not in (select public.belasis_aptas(v_serv))
       and not exists (select 1 from public.belasis_profissional_funcoes f where f.profissional_id = v_pid and f.funcao = 'teste') then
      return jsonb_build_object('ok', false, 'erro', 'profissional_nao_faz',
        'orientacao', case when v_unica is not null
          then 'Esse serviço é feito só pela ' || (select public.belasis_nome_curto(apelido, apelido_belasis, nome) from public.belasis_profissionais where id = v_unica) || '. Diga isso com leveza e pergunte se pode ser com ela.'
          else 'Essa profissional não faz esse serviço. Diga com leveza e pergunte se ela tem outra preferência ou se pode ser com a profissional da vez. Não cite nomes.' end);
    end if;
    v_livre := public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur);
    if v_livre = false then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Diga que infelizmente essa profissional não tem vaga nesse horário. Se veio outra_livre_nesse_horario, ofereça essa pelo nome ("mas tenho com a X, pode ser?"); senão, sugira o próximo horário livre com ela (primeiro de livres_com_ela). Não pergunte preferência. Só agende com outra se a cliente aceitar.',
        'livres_com_ela', public.belasis_horarios_disponiveis(p_servico, p_data, v_prof, 30, p_hora) -> 'mais_proximos',
        'outra_livre_nesse_horario', case when v_unica is null then public.belasis_livres_no_horario(v_serv, p_data, p_hora) ->> 0 end);
    end if;
  else
    for r in select l.profissional_id from public.belasis_lista_da_vez(v_serv, p_data) l order by l.ordem loop
      v_livre := public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur);
      if v_livre is distinct from false then v_pid := r.profissional_id; exit; end if;
    end loop;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', case when exists (select 1 from public.belasis_quem_faz(v_serv)) then 'horario_ocupado' else 'sem_profissional' end,
        'orientacao', 'Ninguém livre nesse horário para esse serviço. Ofereça 2 ou 3 horários de livres_no_dia, sem citar nomes.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 30, p_hora) -> 'mais_proximos');
    end if;
  end if;

  select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_nome from public.belasis_profissionais where id = v_pid;
  v_fim := (p_hora + make_interval(mins => v_dur))::time;
  v_res := public.criar_pre_agendamento(p_conversa_id, p_servico, p_data, p_hora, v_nome, v_serv, v_pid,
                                        v_fim, p_confirmacao, p_observacao);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;

  if v_pend is not null then
    update public.pre_agendamentos set estado = 'cancelado', escrita_estado = 'cancelado', atualizado_em = now() where id = v_pend;
  elsif v_ant_id is not null then
    perform public.belasis_enfileirar_cancelamento(v_ant_id, p_conversa_id, 'remarcação pelo WhatsApp');
  end if;

  -- venda casada: só serviço que tem alguém livre logo depois
  if not p_complemento then
    select coalesce(jsonb_agg(jsonb_build_object('servico', c->>'servico', 'hora', public.hora_curta(v_fim))), '[]') into v_sug
      from jsonb_array_elements(public.belasis_complementos(v_serv)) c
     where jsonb_array_length(public.belasis_livres_no_horario(public.belasis_resolver_servico(c->>'servico'), p_data, v_fim)) > 0;
  end if;

  return jsonb_build_object('ok', true, 'pre_agendado', true, 'confirmado', false,
    'servico', (select descricao from public.belasis_servicos where id = v_serv),
    'profissional', v_nome, 'dia', public.data_curta_pt(p_data), 'hora', public.hora_curta(p_hora),
    'termina', public.hora_curta(v_fim),
    'remarcado_de', case when v_ant_id is not null then public.data_curta_pt(v_ant_data) || ' às ' || public.hora_curta(v_ant_ini::time)
                         when v_pend is not null then 'horário anterior' end,
    'sugestao_complemento', v_sug,
    'orientacao', 'Diga que deixou o horário pré-agendado (dia, hora e profissional) e que a equipe confirma com ela por aqui, curto e natural. Não diga que está confirmado. Se houver sugestao_complemento, ofereça UMA, leve, sem preço e sem nome de profissional, para logo depois. Se ela topar, pergunte se tem preferência de profissional; sem preferência, chame agendar com complemento=true e sem_preferencia=true.');
end;
$function$;

create or replace function public.cancelar_agendamento_whatsapp(p_conversa_id uuid, p_data date default null)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v       record;
  pa      public.pre_agendamentos;
  v_itens integer;
  v_servs text;
begin
  select * into pa from public.pre_agendamentos
   where conversa_id = p_conversa_id and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado'
     and (p_data is null or data = p_data)
   order by data, hora_inicio limit 1;
  select * into v from public.belasis_proximo_agendamento(p_conversa_id, p_data);

  -- o que vai ainda sair na comanda e é o mais próximo: só tira da comanda (todos os itens daquele dia)
  if pa.id is not null and (v.id is null or pa.data <= v.data) then
    with c as (
      update public.pre_agendamentos set estado = 'cancelado', escrita_estado = 'cancelado', atualizado_em = now()
       where conversa_id = p_conversa_id and data = pa.data and escrita_estado = 'aguardando_comanda' and estado <> 'cancelado'
      returning servico, hora_inicio)
    select string_agg(servico, ' e ' order by hora_inicio) into v_servs from c;
    return jsonb_build_object('ok', true, 'cancelado', true, 'dia', public.data_curta_pt(pa.data),
      'hora', public.hora_curta(pa.hora_inicio), 'servico', v_servs, 'profissional', pa.profissional,
      'orientacao', 'Confirme que desmarcou (cite os serviços), com carinho, e pergunte se quer remarcar.');
  end if;

  if v.id is null then
    return jsonb_build_object('ok', false, 'erro', 'sem_agendamento',
      'orientacao', 'Não achei agendamento futuro dela. Pergunte o dia ou transfira (motivo incerteza).');
  end if;
  select jsonb_array_length(a.itens) into v_itens from public.belasis_agendamentos a where a.id = v.id;
  if coalesce(v_itens, 1) > 1 then
    return jsonb_build_object('ok', false, 'erro', 'comanda_com_varios_servicos',
      'orientacao', 'Esse horário está numa comanda com outros serviços. Não cancele sozinha: use transferir_para_humano (incerteza) com o pedido dela e não escreva nada.');
  end if;
  perform public.belasis_enfileirar_cancelamento(v.id, p_conversa_id, 'cancelado pela cliente no WhatsApp');
  perform public.belasis_disparar_sync();
  return jsonb_build_object('ok', true, 'cancelado', true, 'dia', public.data_curta_pt(v.data),
    'hora', public.hora_curta(v.inicio::time), 'servico', v.servico, 'profissional', v.profissional,
    'orientacao', 'Confirme que cancelou, com carinho, e pergunte se quer remarcar.');
end;
$function$;

create or replace function public.belasis_conciliar_pre_agendamentos()
returns integer
language plpgsql
set search_path to ''
as $function$
declare v_n integer;
begin
  with achados as (
    select distinct on (p.id) p.id, a.id ag_id
      from public.pre_agendamentos p
      join public.conversas c on c.id = p.conversa_id
      join public.belasis_clientes bc on bc.telefones && public.variantes_telefone(c.telefone)
      join public.belasis_agendamentos a on a.cliente_id = bc.id and a.data = p.data
                                        and a.status not in ('disconfirm', 'removido')
     where p.estado = 'pendente' and (p.escrita_estado is null or p.escrita_estado = 'falhou')
       and p.data >= current_date - 1
       and exists (select 1 from jsonb_array_elements(a.itens) it
                    where p.hora_inicio is null
                       or abs(extract(epoch from ((it->>'inicio')::time - p.hora_inicio))) <= 5400)
     order by p.id, a.id
  )
  update public.pre_agendamentos p
     set estado = 'lancado', belasis_agendamento_id = achados.ag_id,
         lancado_em = now(), atualizado_em = now()
    from achados
   where p.id = achados.id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$function$;

create or replace function public.iniciar_handoff(p_conversa_id uuid, p_motivo text, p_resumo text)
returns jsonb
language plpgsql
set search_path to ''
as $function$
declare
  v_handoff_id bigint;
  v_conv       public.conversas;
  v_sem_volta  boolean;
  v_notif      jsonb;
  v_motivo     text := p_motivo;
  v_resumo     text := p_resumo;
  v_cfg        jsonb := coalesce(public.cfg('motivos_sem_retorno_automatico'), '["opt_out"]'::jsonb);
begin
  -- negociação é registrada como fora_escopo (motivos do handoff são fixos), com o resumo marcado
  if v_motivo = 'negociacao' then
    v_motivo := 'fora_escopo';
    v_resumo := 'NEGOCIAÇÃO: ' || coalesce(p_resumo, '');
  elsif v_motivo is null or v_motivo not in ('pedido_cliente', 'reclamacao', 'fora_escopo', 'orcamento_visual', 'erro_sistema', 'incerteza', 'opt_out') then
    v_motivo := 'incerteza';
  end if;
  v_sem_volta := jsonb_typeof(v_cfg) = 'array' and (v_cfg ? coalesce(p_motivo, '') or v_cfg ? v_motivo);

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
    'telefone', v_conv.telefone,
    'nome', coalesce(v_conv.nome, v_conv.push_name),
    'bot_volta_em', v_conv.pausado_ate,
    'retorno_automatico', not v_sem_volta,
    'notificacao_id', v_notif->'notificacao_id',
    'destinatarios', v_notif->'destinatarios'
  );
end;
$function$;

-- gerentes_notificados = null (ou qualquer coisa que não seja lista) vira lista vazia
do $$
declare d text;
begin
  d := pg_get_functiondef('public.destinatarios_encaminhamento(text,timestamptz)'::regprocedure);
  if position('jsonb_typeof(public.cfg(''gerentes_notificados''))' in d) > 0 then return; end if;
  d := replace(d, $x$coalesce(public.cfg('gerentes_notificados'), '[]')$x$,
                  $x$case when jsonb_typeof(public.cfg('gerentes_notificados')) = 'array' then public.cfg('gerentes_notificados') else '[]'::jsonb end$x$);
  if position('jsonb_typeof(public.cfg(''gerentes_notificados''))' in d) = 0 then raise exception 'destinatarios: trecho não encontrado'; end if;
  execute d;
end $$;
