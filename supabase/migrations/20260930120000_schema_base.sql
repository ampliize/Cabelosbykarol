-- =====================================================================
-- Cabelos by Karol — Agente WhatsApp × Belasis
-- 001 · Schema base (tabelas, índices, RLS)
-- Acesso: somente n8n via service_role / conexão Postgres. RLS ligado
-- em tudo e sem policies => anon/authenticated não leem nada.
-- =====================================================================

create extension if not exists unaccent with schema extensions;
create extension if not exists pg_cron;

-- ---------------------------------------------------------------------
-- Configuração do bot (chave/valor) — ver seeds em 003
-- ---------------------------------------------------------------------
create table public.config_bot (
  chave         text primary key,
  valor         jsonb not null,
  descricao     text,
  atualizado_em timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Equipe do salão: números ignorados pelo bot e destinatários de handoff
-- ---------------------------------------------------------------------
create table public.equipe (
  id             bigint generated always as identity primary key,
  nome           text not null,
  telefone       text not null unique check (telefone ~ '^[0-9]{12,13}$'),
  papel          text not null default 'atendimento'
                 check (papel in ('dona','recepcao','profissional','atendimento','ampliize')),
  recebe_handoff boolean not null default false,
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Conversas (1 por telefone de cliente)
-- ---------------------------------------------------------------------
create table public.conversas (
  id                    uuid primary key default gen_random_uuid(),
  telefone              text not null unique check (telefone ~ '^[0-9]{12,13}$'),
  whatsapp_jid          text,
  push_name             text,
  nome                  text,
  belasis_cliente_id    integer,
  status                text not null default 'bot'
                        check (status in ('bot','humano_assumiu','aguardando_humano')),
  pausado_ate           timestamptz,
  bot_desativado        boolean not null default false,   -- opt-out da cliente
  ultima_msg_cliente_em timestamptz,                      -- regra R1 (janela 24 h)
  ultima_msg_em         timestamptz,
  criado_em             timestamptz not null default now(),
  atualizado_em         timestamptz not null default now()
);
create index conversas_belasis_cliente_idx on public.conversas (belasis_cliente_id);
create index conversas_status_idx on public.conversas (status) where status <> 'bot';

-- ---------------------------------------------------------------------
-- Mensagens (entrada e saída). message_id único = dedupe de webhook.
-- processada_em nulo em mensagem 'in' = ainda no buffer de agrupamento.
-- ---------------------------------------------------------------------
create table public.mensagens (
  id            bigint generated always as identity primary key,
  conversa_id   uuid not null references public.conversas(id) on delete cascade,
  message_id    text unique,
  direcao       text not null check (direcao in ('in','out')),
  autor         text not null check (autor in ('cliente','bot','humano','sistema')),
  tipo          text not null default 'text'
                check (tipo in ('text','audio','image','video','document','sticker',
                                'reaction','location','contact','outro')),
  texto         text,
  media_url     text,
  processada_em timestamptz,
  raw           jsonb,
  criado_em     timestamptz not null default now()
);
create index mensagens_conversa_idx on public.mensagens (conversa_id, criado_em desc);
create index mensagens_pendentes_idx on public.mensagens (conversa_id, id)
  where direcao = 'in' and processada_em is null;
create index mensagens_criado_idx on public.mensagens (criado_em);

-- ---------------------------------------------------------------------
-- Memória do AI Agent (formato do nó "Postgres Chat Memory" do n8n)
-- session_id = conversas.id
-- ---------------------------------------------------------------------
create table public.n8n_chat_histories (
  id         serial primary key,
  session_id varchar(255) not null,
  message    jsonb not null
);
create index n8n_chat_histories_session_idx on public.n8n_chat_histories (session_id, id);

-- ---------------------------------------------------------------------
-- Execuções do agente (observabilidade: tokens, latência, tool calls)
-- ---------------------------------------------------------------------
create table public.execucoes_agente (
  id           bigint generated always as identity primary key,
  conversa_id  uuid references public.conversas(id) on delete cascade,
  n8n_execucao text,
  entrada      text,
  saida        text,
  tool_calls   jsonb,
  modelo       text,
  tokens_in    integer,
  tokens_out   integer,
  latencia_ms  integer,
  erro         text,
  criado_em    timestamptz not null default now()
);
create index execucoes_agente_conversa_idx on public.execucoes_agente (conversa_id, criado_em desc);
create index execucoes_agente_criado_idx on public.execucoes_agente (criado_em);

-- ---------------------------------------------------------------------
-- Auditoria de escrita no Belasis + idempotência
-- ---------------------------------------------------------------------
create table public.acoes_belasis (
  id                     bigint generated always as identity primary key,
  conversa_id            uuid references public.conversas(id) on delete set null,
  acao                   text not null check (acao in (
                           'criar_cliente','criar_agendamento','cancelar_agendamento',
                           'remarcar_agendamento','confirmar_agendamento')),
  idempotency_key        text not null unique,
  belasis_cliente_id     integer,
  belasis_agendamento_id integer,
  request                jsonb,
  response               jsonb,
  http_status            integer,
  confirmacao_cliente    text,       -- texto literal do "sim" da cliente
  estado                 text not null default 'pendente'
                         check (estado in ('pendente','sucesso','erro')),
  erro                   text,
  criado_em              timestamptz not null default now(),
  concluido_em           timestamptz
);
create index acoes_belasis_conversa_idx on public.acoes_belasis (conversa_id, criado_em desc);

-- ---------------------------------------------------------------------
-- Transferências para humano
-- ---------------------------------------------------------------------
create table public.handoffs (
  id            bigint generated always as identity primary key,
  conversa_id   uuid not null references public.conversas(id) on delete cascade,
  motivo        text not null check (motivo in (
                  'pedido_cliente','reclamacao','fora_escopo','orcamento_visual',
                  'erro_sistema','incerteza','opt_out')),
  resumo        text,
  notificado_em timestamptz,
  atendido_por  text,
  resolvido_em  timestamptz,
  criado_em     timestamptz not null default now()
);
create index handoffs_conversa_idx on public.handoffs (conversa_id, criado_em desc);
create index handoffs_abertos_idx on public.handoffs (criado_em) where resolvido_em is null;

-- ---------------------------------------------------------------------
-- Base de conhecimento (FAQ / políticas) — só itens aprovados vão ao bot
-- ---------------------------------------------------------------------
create table public.kb_itens (
  id            bigint generated always as identity primary key,
  categoria     text not null check (categoria in (
                  'servico','preco','politica','local','horario','pagamento','geral')),
  pergunta      text not null,
  resposta      text not null,
  palavras_chave text[] not null default '{}',
  fonte         text not null default 'cliente'
                check (fonte in ('historico_whatsapp','cliente','belasis','ampliize')),
  aprovado      boolean not null default false,
  ativo         boolean not null default true,
  busca         tsvector,
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index kb_itens_busca_idx on public.kb_itens using gin (busca);

-- ---------------------------------------------------------------------
-- Cache de respostas do Belasis (limite de 30 req/min)
-- ---------------------------------------------------------------------
create table public.cache_belasis (
  chave     text primary key,
  valor     jsonb not null,
  expira_em timestamptz not null,
  criado_em timestamptz not null default now()
);
create index cache_belasis_expira_idx on public.cache_belasis (expira_em);

-- ---------------------------------------------------------------------
-- Limitador de vazão por janela de 1 minuto (Belasis e envio WhatsApp)
-- ---------------------------------------------------------------------
create table public.rate_limit (
  recurso  text not null,
  janela   timestamptz not null,
  chamadas integer not null default 0,
  primary key (recurso, janela)
);

-- ---------------------------------------------------------------------
-- RLS: ligado em tudo, sem policies (service_role ignora RLS)
-- ---------------------------------------------------------------------
alter table public.config_bot         enable row level security;
alter table public.equipe             enable row level security;
alter table public.conversas          enable row level security;
alter table public.mensagens          enable row level security;
alter table public.n8n_chat_histories enable row level security;
alter table public.execucoes_agente   enable row level security;
alter table public.acoes_belasis      enable row level security;
alter table public.handoffs           enable row level security;
alter table public.kb_itens           enable row level security;
alter table public.cache_belasis      enable row level security;
alter table public.rate_limit         enable row level security;
