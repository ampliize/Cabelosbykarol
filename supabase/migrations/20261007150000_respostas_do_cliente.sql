-- =====================================================================
-- Respostas do cliente (checklist de 07/10/2026 — docs/10)
-- Horário, endereço, políticas, serviços com avaliação/teste, equipe com
-- ordem de encaminhamento, piloto, silêncio proativo 20h–06h.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Horário de funcionamento e silêncio proativo
-- ---------------------------------------------------------------------
update public.config_bot set valor =
  '{"seg": null, "ter": ["09:00","18:00"], "qua": ["09:00","18:00"], "qui": ["09:00","18:00"],
    "sex": ["09:00","18:00"], "sab": ["09:00","18:00"], "dom": null}'
 where chave = 'horario_funcionamento';

insert into public.config_bot (chave, valor, descricao) values
  ('fuso_horario', '"America/Maceio"', 'Fuso do salão (Aracaju/SE)'),
  ('silencio_proativo', '{"inicio": "20:00", "fim": "06:00"}',
   'Nesse intervalo o agente NUNCA inicia conversa (qualquer dia). Responder a cliente que escreveu é permitido.'),
  ('belasis_status_agendamento', '"unconfirmed"',
   'Status com que o agente cria agendamento no Belasis (cliente: sempre NÃO CONFIRMADO até validação humana)')
on conflict (chave) do update set valor = excluded.valor, descricao = excluded.descricao;

create or replace function public.salao_aberto(p_em timestamptz default now())
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_local timestamp := p_em at time zone coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio');
  v_dia   text := (array['dom','seg','ter','qua','qui','sex','sab'])[extract(dow from v_local)::int + 1];
  v_faixa jsonb := public.cfg('horario_funcionamento') -> v_dia;
begin
  if v_faixa is null or jsonb_typeof(v_faixa) <> 'array' then
    return false;
  end if;
  return v_local::time >= (v_faixa->>0)::time and v_local::time < (v_faixa->>1)::time;
end;
$$;

-- Para qualquer envio PROATIVO (lembrete, reativação, pós-serviço...):
-- falso entre 20:00 e 06:00, em qualquer dia da semana.
create or replace function public.pode_iniciar_conversa(p_em timestamptz default now())
returns boolean
language plpgsql
stable
set search_path = ''
as $$
declare
  v_cfg   jsonb := coalesce(public.cfg('silencio_proativo'), '{"inicio":"20:00","fim":"06:00"}');
  v_hora  time := (p_em at time zone coalesce(public.cfg('fuso_horario') #>> '{}', 'America/Maceio'))::time;
  v_ini   time := (v_cfg->>'inicio')::time;
  v_fim   time := (v_cfg->>'fim')::time;
begin
  if v_ini > v_fim then
    return not (v_hora >= v_ini or v_hora < v_fim);
  end if;
  return not (v_hora >= v_ini and v_hora < v_fim);
end;
$$;

-- ---------------------------------------------------------------------
-- 2. Equipe: ordem de encaminhamento e disponibilidade
-- ---------------------------------------------------------------------
alter table public.equipe drop constraint equipe_papel_check;
alter table public.equipe add constraint equipe_papel_check
  check (papel in ('dona','recepcao','coordenacao','profissional','atendimento','ampliize'));
alter table public.equipe add column if not exists prioridade integer not null default 1;
alter table public.equipe add column if not exists disponibilidade text not null default 'expediente'
  check (disponibilidade in ('expediente', '24h'));

update public.equipe
   set nome = 'Tauã', papel = 'dona', prioridade = 3, disponibilidade = '24h',
       recebe_handoff = true, recebe_alertas_sistema = true
 where telefone = '5579981256494';

insert into public.equipe (nome, telefone, papel, recebe_handoff, recebe_alertas_sistema, prioridade, disponibilidade) values
  ('Vitória (recepção)',    '5579998134284', 'recepcao',    true, false, 1, 'expediente'),
  ('Emilly (coordenadora)', '5579999216161', 'coordenacao', true, false, 2, '24h')
on conflict (telefone) do update set
  nome = excluded.nome, papel = excluded.papel, recebe_handoff = excluded.recebe_handoff,
  prioridade = excluded.prioridade, disponibilidade = excluded.disponibilidade, ativo = true;

update public.equipe set prioridade = 9, disponibilidade = '24h' where papel = 'ampliize';
update public.painel_usuarios set nome = 'Tauã' where email = 'tauaximenes1234@gmail.com';

-- Quem recebe cada encaminhamento:
--   erro_sistema         → quem recebe alertas de sistema (Tauã + Ampliize)
--   sem_resposta_humana  → o próximo nível disponível (escala)
--   demais               → o primeiro nível disponível (Vitória no expediente; fora dele, Emilly)
create or replace function public.destinatarios_encaminhamento(p_tipo text, p_em timestamptz default now())
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_aberto boolean := public.salao_aberto(p_em);
  v_min    integer;
  v_dest   jsonb;
begin
  if p_tipo = 'erro_sistema' then
    select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone) order by e.prioridade), '[]')
      into v_dest
      from public.equipe e where e.ativo and e.recebe_alertas_sistema;
    return v_dest;
  end if;

  select min(e.prioridade) into v_min
    from public.equipe e
   where e.ativo and e.recebe_handoff and (e.disponibilidade = '24h' or v_aberto);

  if p_tipo = 'sem_resposta_humana' then
    select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone) order by e.prioridade), '[]')
      into v_dest
      from public.equipe e
     where e.ativo and e.recebe_handoff and (e.disponibilidade = '24h' or v_aberto)
       and e.prioridade = (select min(x.prioridade) from public.equipe x
                            where x.ativo and x.recebe_handoff and x.prioridade > v_min
                              and (x.disponibilidade = '24h' or v_aberto));
    if jsonb_array_length(v_dest) > 0 then
      return v_dest;
    end if;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('nome', e.nome, 'telefone', e.telefone)), '[]')
    into v_dest
    from public.equipe e
   where e.ativo and e.recebe_handoff and e.prioridade = v_min
     and (e.disponibilidade = '24h' or v_aberto);
  return v_dest;
end;
$$;

create or replace function public.encaminhar_para_responsavel(
  p_tipo             text,
  p_conversa_id      uuid    default null,
  p_motivo           text    default null,
  p_resumo           text    default null,
  p_mensagem_cliente text    default null,
  p_handoff_id       bigint  default null
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_conv  public.conversas;
  v_dest  jsonb;
  v_id    bigint;
  v_msg   text := p_mensagem_cliente;
begin
  if p_conversa_id is not null then
    select * into v_conv from public.conversas where id = p_conversa_id;
    if v_msg is null then
      select string_agg(texto, E'\n' order by id) into v_msg
        from (select id, texto from public.mensagens
               where conversa_id = p_conversa_id and autor = 'cliente' and texto is not null
               order by id desc limit 3) t;
    end if;
  end if;

  v_dest := public.destinatarios_encaminhamento(p_tipo);

  insert into public.notificacoes_equipe
    (conversa_id, handoff_id, tipo, motivo, resumo, mensagem_cliente, telefone_cliente, nome_cliente, destinatarios)
  values
    (p_conversa_id, p_handoff_id, p_tipo, p_motivo, p_resumo, v_msg, v_conv.telefone,
     coalesce(v_conv.nome, v_conv.push_name), v_dest)
  returning id into v_id;

  perform public.disparar_notificacao(v_id);

  return jsonb_build_object('notificacao_id', v_id, 'destinatarios', v_dest,
                            'sem_destinatario', jsonb_array_length(v_dest) = 0);
end;
$$;

-- ---------------------------------------------------------------------
-- 3. Piloto: Karol, Tauã e Emilly testam como clientes.
--    Número da equipe que está na whitelist do piloto é atendido como cliente.
-- ---------------------------------------------------------------------
update public.config_bot set valor = '["5579998882219", "5579981256494", "5579999216161"]'
 where chave = 'whitelist_piloto';

do $$
declare
  v_def text := pg_get_functiondef('public.registrar_mensagem_entrada(text,text,boolean,text,text,text,text,text,jsonb)'::regprocedure);
  v_old text := 'if exists (select 1 from public.equipe e where e.telefone = v_tel and e.ativo) then';
  v_new text := 'if exists (select 1 from public.equipe e where e.telefone = v_tel and e.ativo)
     and not (coalesce((public.cfg(''modo_piloto''))::boolean, false)
              and coalesce(public.cfg(''whitelist_piloto''), ''[]''::jsonb) ? v_tel) then';
begin
  if position(v_old in v_def) = 0 then
    raise exception 'trecho da equipe não encontrado em registrar_mensagem_entrada';
  end if;
  execute replace(v_def, v_old, v_new);
end;
$$;

-- ---------------------------------------------------------------------
-- 4. Mensagens automáticas do salão (Belasis) e avisos enviados à equipe
--    não contam como "equipe assumiu".
-- ---------------------------------------------------------------------
update public.config_bot
   set valor = (select jsonb_agg(distinct p) from jsonb_array_elements_text(valor || '[
     "^(🔔|❓|⚠️|🚨|⏰|📅|✅) \\*",
     "seja bem[- ]vind",
     "avalia(r|[cç][aã]o).{0,60}google|google.{0,60}avalia",
     "cuidados (com|para|p/) (o |seu |os )?cabel",
     "(faz|tem) (um )?tempo que (voc[eê] )?n[aã]o (vem|aparece)",
     "parab[eé]ns pelo (seu )?anivers"
   ]'::jsonb) p)
 where chave = 'padroes_mensagens_automaticas';

-- ---------------------------------------------------------------------
-- 5. Base de conhecimento aprovada pelo salão
-- ---------------------------------------------------------------------
insert into public.kb_itens (categoria, pergunta, resposta, palavras_chave, fonte, aprovado) values
  ('horario', 'Qual o horário de funcionamento? Abre domingo ou segunda?',
   'Funcionamos de terça a sábado, das 9h às 18h. Domingo e segunda o salão fica fechado.',
   '{horario,funcionamento,abre,fecha,domingo,segunda,sabado,feriado}', 'cliente', true),
  ('local', 'Qual o endereço do salão? Onde fica?',
   'Rua Fenelon Santos, 132, Salgado Filho, Aracaju/SE. Fica na rua da Sorveteria Tchê, já perto do canal.',
   '{endereco,onde,localizacao,fica,rua,aracaju,referencia,sorveteria}', 'cliente', true),
  ('local', 'Tem estacionamento?',
   'Não temos estacionamento próprio; o estacionamento é na rua.',
   '{estacionamento,estacionar,carro,vaga}', 'cliente', true),
  ('pagamento', 'Quais as formas de pagamento?',
   'Aceitamos PIX, dinheiro e cartão.',
   '{pagamento,pix,cartao,dinheiro,credito,debito,pagar}', 'cliente', true),
  ('politica', 'Precisa pagar sinal para agendar?',
   'Não cobramos sinal para agendar.',
   '{sinal,adiantado,deposito,reserva,"pagar antes"}', 'cliente', true),
  ('politica', 'Posso cancelar ou remarcar? Precisa de antecedência?',
   'Pode cancelar ou remarcar quando precisar, não exigimos antecedência mínima. Só pedimos que avise para liberarmos o horário.',
   '{cancelar,cancelamento,remarcar,desmarcar,"mudar horario",antecedencia}', 'cliente', true),
  ('politica', 'Qual a tolerância de atraso? E se eu me atrasar?',
   'A tolerância é de 15 minutos. Se o atraso passar de 20 minutos e não conseguirmos falar com você, o agendamento é cancelado.',
   '{atraso,atrasada,atrasar,tolerancia,falta,faltar}', 'cliente', true),
  ('servico', 'Alongamento capilar precisa de avaliação?',
   'Sim. O alongamento capilar precisa de uma avaliação capilar antes, para ver se é possível fazer o procedimento. A avaliação é gratuita.',
   '{alongamento,"mega hair",extensao,avaliacao}', 'cliente', true),
  ('servico', 'Luzes, selagem ou coloração precisam de teste?',
   'Sim. Luzes, selagem e coloração precisam de um teste de mecha antes do serviço. O teste é gratuito.',
   '{luzes,mechas,selagem,coloracao,tintura,pintar,cor,"teste de mecha"}', 'cliente', true);

-- ---------------------------------------------------------------------
-- Permissões
-- ---------------------------------------------------------------------
do $$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('salao_aberto', 'pode_iniciar_conversa', 'destinatarios_encaminhamento')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end;
$$;
