-- CRM (29/10):
-- * pausa automática: humano escreveu pelo número do salão → a IA pausa naquela conversa e só volta
--   depois de 5 min sem a equipe responder (registrar_mensagem_entrada já pausa; aqui os tempos)
-- * painel: lista de conversas + histórico, assumir/devolver, funil, alertas e configurações editáveis
--   (equipe, gerência, função das profissionais e regras dos serviços). Tudo exige painel_autorizado().

update public.config_bot set valor = '5'::jsonb where chave in ('devolver_ao_bot_apos_minutos', 'minutos_tolerancia_resposta_humana');

-- ------------------------------------------------------------------ conversas
create or replace function public.painel_conversas(p_filtro text default 'todas', p_busca text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'ultima_msg_em' desc), '[]') from (
    select jsonb_build_object(
             'id', c.id, 'nome', coalesce(nullif(c.nome, ''), c.push_name, 'Cliente'), 'telefone', c.telefone,
             'status', c.status, 'pausado_ate', c.pausado_ate, 'bot_desativado', c.bot_desativado,
             'ultima_msg_em', c.ultima_msg_em, 'ultima_msg_cliente_em', c.ultima_msg_cliente_em,
             'ultimo_texto', (select left(coalesce(m.texto, '[' || m.tipo || ']'), 90) from public.mensagens m
                               where m.conversa_id = c.id order by m.id desc limit 1),
             'ultimo_autor', (select m.autor from public.mensagens m where m.conversa_id = c.id order by m.id desc limit 1),
             'handoff', (select jsonb_build_object('motivo', h.motivo, 'resumo', h.resumo, 'criado_em', h.criado_em)
                           from public.handoffs h where h.conversa_id = c.id and h.resolvido_em is null order by h.id desc limit 1),
             'pre_agendamentos', (select count(*) from public.pre_agendamentos p
                                   where p.conversa_id = c.id and p.estado <> 'cancelado' and p.data >= current_date)) x
      from public.conversas c
     where (p_filtro = 'todas'
            or (p_filtro = 'equipe' and c.status <> 'bot')
            or (p_filtro = 'aguardando' and c.status = 'aguardando_humano'))
       and (nullif(btrim(coalesce(p_busca, '')), '') is null
            or c.telefone like '%' || regexp_replace(p_busca, '\D', '', 'g') || '%' and regexp_replace(p_busca, '\D', '', 'g') <> ''
            or coalesce(c.nome, c.push_name, '') ilike '%' || btrim(p_busca) || '%')
     order by c.ultima_msg_em desc nulls last
     limit 100) q);
end;
$function$;

create or replace function public.painel_conversa(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare c public.conversas;
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  select * into c from public.conversas where id = p_id;
  if c.id is null then return null; end if;
  return jsonb_build_object(
    'id', c.id, 'nome', coalesce(nullif(c.nome, ''), c.push_name, 'Cliente'), 'telefone', c.telefone,
    'status', c.status, 'pausado_ate', c.pausado_ate, 'bot_desativado', c.bot_desativado,
    'mensagens', (select coalesce(jsonb_agg(jsonb_build_object('em', m.criado_em, 'autor', m.autor, 'tipo', m.tipo, 'texto', m.texto)
                                            order by m.id), '[]')
                    from (select * from public.mensagens where conversa_id = p_id order by id desc limit 150) m),
    'pre_agendamentos', (select coalesce(jsonb_agg(jsonb_build_object('servico', p.servico, 'profissional', p.profissional,
                            'data', p.data, 'hora', to_char(p.hora_inicio, 'HH24:MI'), 'estado', p.estado, 'escrita', p.escrita_estado)
                            order by p.data desc, p.hora_inicio), '[]')
                           from public.pre_agendamentos p where p.conversa_id = p_id),
    'handoffs', (select coalesce(jsonb_agg(jsonb_build_object('motivo', h.motivo, 'resumo', h.resumo, 'criado_em', h.criado_em,
                    'atendido_por', h.atendido_por, 'resolvido_em', h.resolvido_em) order by h.id desc), '[]')
                   from public.handoffs h where h.conversa_id = p_id));
end;
$function$;

-- assumir: pausa a IA nesta conversa (até devolver ou pausa_humano_horas); devolver: a IA volta já
-- (o cron devolver_conversas_ao_bot responde o que ficou pendente)
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
    update public.conversas set pausado_ate = now(), bot_desativado = false
     where id = p_id and status <> 'bot';
    perform public.devolver_conversas_ao_bot();
  end if;
  return (select jsonb_build_object('ok', true, 'status', status, 'pausado_ate', pausado_ate) from public.conversas where id = p_id);
end;
$function$;

-- ------------------------------------------------------------------ funil e alertas
create or replace function public.painel_funil(p_dias integer default 7)
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare v_ini timestamptz := date_trunc('day', now() at time zone 'America/Maceio') at time zone 'America/Maceio'
                             - make_interval(days => greatest(coalesce(p_dias, 7), 1) - 1);
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return (
    with conv as (select distinct conversa_id from public.mensagens where autor = 'cliente' and criado_em >= v_ini),
    pre as (select * from public.pre_agendamentos where criado_em >= v_ini),
    lanc as (select distinct belasis_agendamento_id id from pre where belasis_agendamento_id is not null and estado <> 'cancelado')
    select jsonb_build_object(
      'conversas', (select count(*) from conv),
      'transferidas', (select count(distinct conversa_id) from public.handoffs where criado_em >= v_ini),
      'com_pre_agendamento', (select count(distinct conversa_id) from pre where estado <> 'cancelado'),
      'servicos_pre_agendados', (select count(*) from pre where estado <> 'cancelado'),
      'comandas_no_belasis', (select count(*) from lanc),
      'confirmadas', (select count(*) from lanc join public.belasis_agendamentos a on a.id = lanc.id where a.status in ('confirmed', 'waiting')),
      'canceladas', (select count(*) from lanc join public.belasis_agendamentos a on a.id = lanc.id where a.status = 'disconfirm')
                    + (select count(*) from pre where estado = 'cancelado'),
      'faturamento_previsto', (select round(coalesce(sum(s.preco_cents), 0) / 100.0, 2) from pre
                                 join public.belasis_servicos s on s.id = pre.servico_id where pre.estado <> 'cancelado')));
end;
$function$;

create or replace function public.painel_alertas()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(a order by a->>'nivel', a->>'em' desc), '[]') from (
    select jsonb_build_object('nivel', '1', 'tipo', 'agente_pausado', 'titulo', 'Agente de IA está PAUSADO',
             'detalhe', 'Ninguém está sendo atendido automaticamente.', 'em', now()) a
     where not coalesce((public.cfg('bot_ativo'))::boolean, false)
    union all
    select jsonb_build_object('nivel', '1', 'tipo', 'comanda_falhou', 'titulo', 'Agendamento não entrou no Belasis',
             'detalhe', coalesce(c.nome, c.push_name, 'Cliente') || ': ' || p.servico || ' em ' || to_char(p.data, 'DD/MM') || ' ' || to_char(p.hora_inicio, 'HH24:MI')
                        || ' · ' || coalesce(left(p.escrita_erro, 120), ''),
             'conversa_id', p.conversa_id, 'em', p.atualizado_em)
      from public.pre_agendamentos p join public.conversas c on c.id = p.conversa_id
     where p.escrita_estado = 'falhou' and p.estado = 'pendente' and p.data >= current_date
    union all
    select jsonb_build_object('nivel', '2', 'tipo', 'aguardando_equipe', 'titulo', 'Cliente esperando a equipe',
             'detalhe', coalesce(c.nome, c.push_name, 'Cliente') || ' · ' || coalesce(h.motivo, '') || coalesce(': ' || left(h.resumo, 120), ''),
             'conversa_id', c.id, 'em', h.criado_em)
      from public.conversas c
      join lateral (select * from public.handoffs h where h.conversa_id = c.id and h.resolvido_em is null order by h.id desc limit 1) h on true
     where c.status = 'aguardando_humano'
    union all
    select jsonb_build_object('nivel', '2', 'tipo', 'aviso_nao_enviado', 'titulo', 'Aviso para a equipe não foi entregue',
             'detalhe', n.tipo || coalesce(' · ' || left(n.erro, 120), ''), 'conversa_id', n.conversa_id, 'em', n.criado_em)
      from public.notificacoes_equipe n
     where n.estado = 'erro' and n.criado_em > now() - interval '24 hours'
  ) q);
end;
$function$;

-- ------------------------------------------------------------------ configurações
create or replace function public.painel_config()
returns jsonb
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  return jsonb_build_object(
    'equipe', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'nome', e.nome, 'telefone', e.telefone, 'papel', e.papel,
                 'prioridade', e.prioridade, 'disponibilidade', e.disponibilidade, 'recebe_handoff', e.recebe_handoff,
                 'recebe_alertas_sistema', e.recebe_alertas_sistema, 'ativo', e.ativo) order by e.prioridade, e.nome), '[]')
                 from public.equipe e),
    'gerentes', case when jsonb_typeof(public.cfg('gerentes_notificados')) = 'array' then public.cfg('gerentes_notificados') else '[]'::jsonb end,
    'profissionais', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id,
                        'nome', public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome), 'nome_completo', p.nome,
                        'funcao', f.funcao) order by p.nome), '[]')
                        from public.belasis_profissionais p left join public.belasis_profissional_funcoes f on f.profissional_id = p.id
                       where p.ativo),
    'servicos', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'servico', s.descricao, 'categoria', g.nome,
                   'quem', r.quem, 'profissional_id', r.profissional_id, 'prioritaria', r.prioritaria_sem_preferencia,
                   'da_planilha', r.nome_planilha is not null) order by g.nome, s.descricao), '[]')
                   from public.belasis_servicos s left join public.belasis_grupos g on g.id = s.group_id
                   left join public.belasis_servico_regras r on r.servico_id = s.id
                  where s.ativo));
end;
$function$;

create or replace function public.painel_salvar_equipe(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v_id bigint;
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  if nullif(p->>'id', '') is null then
    insert into public.equipe (nome, telefone, papel, prioridade, disponibilidade, recebe_handoff, recebe_alertas_sistema, ativo)
    values (btrim(p->>'nome'), public.normalizar_telefone(p->>'telefone'), coalesce(nullif(p->>'papel', ''), 'atendimento'),
            coalesce((p->>'prioridade')::int, 5), coalesce(nullif(p->>'disponibilidade', ''), 'expediente'),
            coalesce((p->>'recebe_handoff')::boolean, true), coalesce((p->>'recebe_alertas_sistema')::boolean, false),
            coalesce((p->>'ativo')::boolean, true))
    returning id into v_id;
  else
    update public.equipe set
      nome = coalesce(nullif(btrim(p->>'nome'), ''), nome),
      telefone = coalesce(public.normalizar_telefone(p->>'telefone'), telefone),
      papel = coalesce(nullif(p->>'papel', ''), papel),
      prioridade = coalesce((p->>'prioridade')::int, prioridade),
      disponibilidade = coalesce(nullif(p->>'disponibilidade', ''), disponibilidade),
      recebe_handoff = coalesce((p->>'recebe_handoff')::boolean, recebe_handoff),
      recebe_alertas_sistema = coalesce((p->>'recebe_alertas_sistema')::boolean, recebe_alertas_sistema),
      ativo = coalesce((p->>'ativo')::boolean, ativo)
    where id = (p->>'id')::bigint
    returning id into v_id;
  end if;
  return jsonb_build_object('ok', v_id is not null, 'id', v_id);
end;
$function$;

create or replace function public.painel_salvar_gerentes(p_telefones jsonb)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare v jsonb;
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(distinct t), '[]') into v
    from (select public.normalizar_telefone(x) t from jsonb_array_elements_text(coalesce(p_telefones, '[]')) x) q
   where t is not null;
  update public.config_bot set valor = v where chave = 'gerentes_notificados';
  return jsonb_build_object('ok', true, 'gerentes', v);
end;
$function$;

create or replace function public.painel_salvar_funcao(p_profissional_id integer, p_funcao text)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  if nullif(p_funcao, '') is null then
    delete from public.belasis_profissional_funcoes where profissional_id = p_profissional_id;
  else
    insert into public.belasis_profissional_funcoes (profissional_id, funcao) values (p_profissional_id, p_funcao)
    on conflict (profissional_id) do update set funcao = excluded.funcao, atualizado_em = now();
  end if;
  return jsonb_build_object('ok', true);
end;
$function$;

create or replace function public.painel_salvar_regra(p_servico_id integer, p_quem text, p_profissional_id integer default null,
                                                      p_prioritaria integer default null)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not public.painel_autorizado() then raise exception 'acesso_negado' using errcode = '42501'; end if;
  if p_quem = 'unica' and p_profissional_id is null then
    return jsonb_build_object('ok', false, 'erro', 'Escolha a profissional que faz esse serviço.');
  end if;
  insert into public.belasis_servico_regras (servico_id, quem, profissional_id, prioritaria_sem_preferencia, nome_planilha)
  values (p_servico_id, p_quem, case when p_quem = 'unica' then p_profissional_id end, p_prioritaria, 'painel')
  on conflict (servico_id) do update set quem = excluded.quem, profissional_id = excluded.profissional_id,
    prioritaria_sem_preferencia = excluded.prioritaria_sem_preferencia, nome_planilha = coalesce(belasis_servico_regras.nome_planilha, 'painel'),
    atualizado_em = now();
  return jsonb_build_object('ok', true);
end;
$function$;

revoke all on function public.painel_conversas(text, text), public.painel_conversa(uuid), public.painel_assumir(uuid, boolean),
  public.painel_funil(integer), public.painel_alertas(), public.painel_config(), public.painel_salvar_equipe(jsonb),
  public.painel_salvar_gerentes(jsonb), public.painel_salvar_funcao(integer, text),
  public.painel_salvar_regra(integer, text, integer, integer) from public, anon;
grant execute on function public.painel_conversas(text, text), public.painel_conversa(uuid), public.painel_assumir(uuid, boolean),
  public.painel_funil(integer), public.painel_alertas(), public.painel_config(), public.painel_salvar_equipe(jsonb),
  public.painel_salvar_gerentes(jsonb), public.painel_salvar_funcao(integer, text),
  public.painel_salvar_regra(integer, text, integer, integer) to authenticated;
