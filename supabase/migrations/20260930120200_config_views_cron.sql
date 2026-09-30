-- =====================================================================
-- 003 · Configuração inicial, views de acompanhamento e rotina de limpeza
-- =====================================================================

insert into public.config_bot (chave, valor, descricao) values
  ('bot_ativo',                        'true',          'Kill switch: false desliga todas as respostas e envios do bot'),
  ('modo_piloto',                      'true',          'true = bot só responde números em whitelist_piloto (usar até o go-live)'),
  ('whitelist_piloto',                 '[]',            'Telefones normalizados (5511987654321) liberados no modo piloto'),
  ('pausa_humano_horas',               '4',             'Horas de silêncio do bot depois que alguém da equipe responde'),
  ('timeout_aguardando_humano_horas',  '12',            'Horas até o bot voltar numa conversa transferida sem resposta humana'),
  ('janela_agrupamento_segundos',      '8',             'Espera para juntar mensagens em rajada antes de responder'),
  ('envio_intervalo_min_ms',           '3000',          'Intervalo mínimo entre mensagens do bot na mesma conversa (R4)'),
  ('envio_limite_por_minuto',          '20',            'Máximo de mensagens do bot por minuto no número (R4)'),
  ('belasis_limite_por_minuto',        '25',            'Chamadas à API Belasis por minuto (limite oficial: 30)'),
  ('dias_busca_horarios',              '14',            'Até quantos dias à frente procurar horário'),
  ('max_opcoes_horario',               '3',             'Quantas opções de horário oferecer'),
  ('status_agendamento_bot',           '"confirmed"',   'Status do agendamento criado pelo bot no Belasis (confirmed | unconfirmed)'),
  ('padroes_mensagens_automaticas',    '[]',            'Regex de mensagens automáticas enviadas pelo número (ex.: lembretes da extensão Belasis) que NÃO devem pausar o bot'),
  ('horario_funcionamento',            '{"seg": null, "ter": null, "qua": null, "qui": null, "sex": null, "sab": null, "dom": null}',
                                                        'Preencher: {"ter": ["09:00","19:00"], ...}; null = fechado'),
  ('retencao_mensagens_dias',          '180',           'Retenção de mensagens e logs (LGPD)')
on conflict (chave) do nothing;

-- ---------------------------------------------------------------------
-- Views de acompanhamento (security_invoker: respeitam RLS de quem consulta)
-- ---------------------------------------------------------------------
create or replace view public.vw_metricas_diarias
with (security_invoker = true) as
with msgs as (
  select (criado_em at time zone 'America/Sao_Paulo')::date as dia,
         count(distinct conversa_id)                        as conversas,
         count(*) filter (where autor = 'cliente')          as msgs_clientes,
         count(*) filter (where autor = 'bot')              as msgs_bot,
         count(*) filter (where autor = 'humano')           as msgs_humano
    from public.mensagens
   group by 1
),
hand as (
  select (criado_em at time zone 'America/Sao_Paulo')::date as dia, count(*) as handoffs
    from public.handoffs group by 1
),
acoes as (
  select (criado_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*) filter (where acao = 'criar_agendamento'    and estado = 'sucesso') as agendamentos,
         count(*) filter (where acao = 'remarcar_agendamento' and estado = 'sucesso') as remarcacoes,
         count(*) filter (where acao = 'cancelar_agendamento' and estado = 'sucesso') as cancelamentos,
         count(*) filter (where estado = 'erro')                                      as erros_belasis
    from public.acoes_belasis group by 1
),
exec as (
  select (criado_em at time zone 'America/Sao_Paulo')::date as dia,
         count(*)                                           as execucoes_agente,
         percentile_cont(0.95) within group (order by latencia_ms) as latencia_p95_ms,
         sum(tokens_in)                                     as tokens_in,
         sum(tokens_out)                                    as tokens_out,
         count(*) filter (where erro is not null)           as erros_agente
    from public.execucoes_agente group by 1
)
select m.dia, m.conversas, m.msgs_clientes, m.msgs_bot, m.msgs_humano,
       coalesce(h.handoffs, 0)       as handoffs,
       coalesce(a.agendamentos, 0)   as agendamentos,
       coalesce(a.remarcacoes, 0)    as remarcacoes,
       coalesce(a.cancelamentos, 0)  as cancelamentos,
       coalesce(a.erros_belasis, 0)  as erros_belasis,
       coalesce(e.execucoes_agente, 0) as execucoes_agente,
       e.latencia_p95_ms, e.tokens_in, e.tokens_out,
       coalesce(e.erros_agente, 0)   as erros_agente
  from msgs m
  left join hand  h using (dia)
  left join acoes a using (dia)
  left join exec  e using (dia)
 order by m.dia desc;

create or replace view public.vw_handoffs_abertos
with (security_invoker = true) as
select h.id, h.criado_em, h.motivo, h.resumo, h.atendido_por,
       c.telefone, coalesce(c.nome, c.push_name) as nome, c.status, c.pausado_ate
  from public.handoffs h
  join public.conversas c on c.id = h.conversa_id
 where h.resolvido_em is null
 order by h.criado_em;

-- Checagem de segurança: escrita no Belasis sem confirmação registrada
create or replace view public.vw_alertas_escrita_sem_confirmacao
with (security_invoker = true) as
select a.id, a.criado_em, a.acao, a.estado, a.conversa_id, a.request
  from public.acoes_belasis a
 where a.acao <> 'criar_cliente'
   and coalesce(btrim(a.confirmacao_cliente), '') = '';

revoke all on public.vw_metricas_diarias, public.vw_handoffs_abertos,
              public.vw_alertas_escrita_sem_confirmacao from anon, authenticated;

-- Defesa em profundidade: além do RLS, nenhum privilégio para anon/authenticated
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- ---------------------------------------------------------------------
-- Limpeza diária às 03:17 (America/Sao_Paulo = 06:17 UTC)
-- ---------------------------------------------------------------------
select cron.schedule('cbk-limpeza-diaria', '17 6 * * *', $$select public.limpar_dados_antigos()$$);
