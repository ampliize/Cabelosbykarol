-- Teste de 27/10 à noite:
-- 1) só 3 de 5 profissionais apareciam → quem_faz olha 365 dias e a pergunta não lista nomes
--    (se a cliente pedir, vão todas). Sem preferência = LISTA DA VEZ: prioritária do serviço primeiro
--    (Karol em "Manutenção Alongamento", se livre), depois quem tem menos atendimentos no dia,
--    depois quem recebeu agendamento pelo WhatsApp há mais tempo.
-- 2) tudo caía na agenda Ampliize (trava de teste) → belasis_escrita_profissional_teste = null.
-- 3) venda casada ofereceu profissional sem horário → a sugestão já vem com quem está livre ao terminar
--    o 1º serviço; complemento com profissional ocupada devolve horario_ocupado (não troca sozinho).
-- 4) preço/duração só se a cliente perguntar (orientações sem preço; prompt no n8n).

update public.config_bot set valor = 'null'::jsonb where chave = 'belasis_escrita_profissional_teste';

insert into public.config_bot (chave, valor, descricao) values
  ('profissional_prioritaria', '[{"grupo": "Manutenção Alongamento", "profissional_id": 37416}]'::jsonb,
   'Sem preferência da cliente: essa profissional vem primeiro nos serviços do grupo (se estiver livre); depois, lista da vez')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

create or replace function public.belasis_quem_faz(p_servico_id integer)
returns table (profissional_id integer, n bigint)
language sql
stable
set search_path to ''
as $function$
  select (it->>'profissional_id')::int, count(*)
    from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
   where (it->>'servico_id')::int = p_servico_id and a.status not in ('disconfirm', 'removido')
     and a.data >= (now() at time zone 'America/Maceio')::date - 365
     and (it->>'profissional_id')::int in (select public.belasis_profissionais_que_atendem())
   group by 1 order by 2 desc;
$function$;

-- ordem de atendimento para quem não tem preferência
create or replace function public.belasis_lista_da_vez(p_servico_id integer, p_data date)
returns table (profissional_id integer, ordem integer)
language sql
stable
set search_path to ''
as $function$
  with pri as (
    select (x->>'profissional_id')::int pid
      from jsonb_array_elements(coalesce(public.cfg('profissional_prioritaria'), '[]')) x
      join public.belasis_servicos s on s.id = p_servico_id
      join public.belasis_grupos g on g.id = s.group_id and g.nome = x->>'grupo'
     where (x->>'profissional_id')::int in (select public.belasis_profissionais_que_atendem())
  ), cand as (
    select q.profissional_id pid, q.n from public.belasis_quem_faz(p_servico_id) q
    union select pid, 0 from pri where pid not in (select q.profissional_id from public.belasis_quem_faz(p_servico_id) q)
  )
  select c.pid, (row_number() over (order by
           (c.pid in (select pid from pri)) desc,
           (select count(*) from public.belasis_agendamentos a, jsonb_array_elements(a.itens) it
             where a.data = p_data and a.status not in ('disconfirm', 'removido')
               and (it->>'profissional_id')::int = c.pid),
           (select max(pa.criado_em) from public.pre_agendamentos pa where pa.profissional_id = c.pid) nulls first,
           c.n desc))::int
    from cand c;
$function$;

-- nomes livres para um serviço num horário, na ordem da lista da vez
create or replace function public.belasis_livres_no_horario(p_servico_id integer, p_data date, p_hora time)
returns jsonb
language sql
stable
set search_path to ''
as $function$
  select coalesce(jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) order by l.ordem), '[]')
    from public.belasis_lista_da_vez(p_servico_id, p_data) l
    join public.belasis_profissionais p on p.id = l.profissional_id
    join public.belasis_servicos s on s.id = p_servico_id
   where public.belasis_profissional_livre(l.profissional_id, p_data, p_hora, coalesce(s.duracao_min, 60)) is distinct from false;
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
  v_fim   time;
  v_sug   jsonb := '[]';
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

  if not p_complemento and not public.hora_mencionada(p_conversa_id, p_hora) then
    return jsonb_build_object('ok', false, 'erro', 'hora_nao_informada',
      'orientacao', 'A cliente ainda não escolheu o horário. Pergunte que horário ela prefere (pode usar consultar_horarios e sugerir 2 ou 3). Não escolha por ela.');
  end if;

  if v_prof is null and not p_sem_preferencia and not p_complemento then
    return jsonb_build_object('ok', false, 'erro', 'perguntar_profissional',
      'orientacao', 'Pergunte só "tem preferência de profissional?" (sem listar nomes). Se ela perguntar quem faz, cite os nomes de quem_faz.',
      'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) order by q.n desc)
                     from public.belasis_quem_faz(v_serv) q join public.belasis_profissionais p on p.id = q.profissional_id));
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
        'orientacao', 'Não achei essa profissional. Pergunte de novo o nome ou ofereça quem faz o serviço.',
        'quem_faz', (select jsonb_agg(public.belasis_nome_curto(p.apelido, p.apelido_belasis, p.nome) order by q.n desc)
                       from public.belasis_quem_faz(v_serv) q join public.belasis_profissionais p on p.id = q.profissional_id));
    end if;
    v_livre := public.belasis_profissional_livre(v_pid, p_data, p_hora, v_dur);
    if v_livre = false then
      return jsonb_build_object('ok', false, 'erro', 'horario_ocupado',
        'orientacao', 'Esse horário não está livre com essa profissional. Diga isso e ofereça 2 ou 3 opções abaixo (outro horário com ela ou outra profissional livre nesse horário). Não agende com outra sem ela aceitar.',
        'livres_com_ela', public.belasis_horarios_disponiveis(p_servico, p_data, v_prof, 30, p_hora) -> 'mais_proximos',
        'outras_no_mesmo_horario', public.belasis_livres_no_horario(v_serv, p_data, p_hora));
    end if;
  else
    -- sem preferência: lista da vez (prioritária do serviço primeiro, se livre)
    for r in select l.profissional_id from public.belasis_lista_da_vez(v_serv, p_data) l order by l.ordem loop
      v_livre := public.belasis_profissional_livre(r.profissional_id, p_data, p_hora, v_dur);
      if v_livre is distinct from false then v_pid := r.profissional_id; exit; end if;
    end loop;
    if v_pid is null then
      return jsonb_build_object('ok', false, 'erro', case when exists (select 1 from public.belasis_quem_faz(v_serv)) then 'horario_ocupado' else 'sem_profissional' end,
        'orientacao', 'Ninguém livre nesse horário para esse serviço. Ofereça 2 ou 3 opções abaixo, sem listar tudo.',
        'livres_no_dia', public.belasis_horarios_disponiveis(p_servico, p_data, null, 30, p_hora) -> 'mais_proximos');
    end if;
  end if;

  if p_remarcar then
    select x.id, x.data, x.inicio into v_ant_id, v_ant_data, v_ant_ini from public.belasis_proximo_agendamento(p_conversa_id) x;
  end if;

  select public.belasis_nome_curto(apelido, apelido_belasis, nome) into v_nome from public.belasis_profissionais where id = v_pid;
  v_fim := (p_hora + make_interval(mins => v_dur))::time;
  v_res := public.criar_pre_agendamento(p_conversa_id, p_servico, p_data, p_hora, v_nome, v_serv, v_pid,
                                        v_fim, p_confirmacao, p_observacao);
  if not coalesce((v_res->>'ok')::boolean, false) then return v_res; end if;

  if v_ant_id is not null then
    perform public.belasis_enfileirar_cancelamento(v_ant_id, p_conversa_id, 'remarcação pelo WhatsApp');
  end if;

  -- venda casada só com quem está livre quando o 1º serviço termina
  if not p_complemento then
    select coalesce(jsonb_agg(x), '[]') into v_sug from (
      select jsonb_build_object('servico', c->>'servico', 'hora', public.hora_curta(v_fim),
               'livres', public.belasis_livres_no_horario(public.belasis_resolver_servico(c->>'servico'), p_data, v_fim)) x
        from jsonb_array_elements(public.belasis_complementos(v_serv)) c) s
     where jsonb_array_length(x->'livres') > 0;
  end if;

  return jsonb_build_object('ok', true, 'agendado', true,
    'servico', (select descricao from public.belasis_servicos where id = v_serv),
    'profissional', v_nome, 'dia', public.data_curta_pt(p_data), 'hora', public.hora_curta(p_hora),
    'termina', public.hora_curta(v_fim),
    'remarcado_de', case when v_ant_id is not null then public.data_curta_pt(v_ant_data) || ' às ' || public.hora_curta(v_ant_ini::time) end,
    'sugestao_complemento', v_sug,
    'orientacao', 'Diga que está agendado (dia, hora e profissional), curto e natural. Se houver sugestao_complemento, ofereça UMA, leve, sem preço (só diga o preço se ela perguntar), para logo depois; se ela topar, pergunte se tem preferência entre as de "livres" (só essas). Não insista.');
end;
$function$;

-- n8n (CBK · Agente Core, 27/10 noite): prompt sem preço/duração a não ser que a cliente pergunte;
-- profissional: perguntar preferência sem listar nomes; complemento só com quem está em "livres".
