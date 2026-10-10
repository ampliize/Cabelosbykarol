# Belasis → Supabase (somente leitura) e publicação do painel

## Como funciona a sincronização

```
pg_cron (1x/min) ──► belasis_disparar_sync() ──► Edge Function belasis-sync ──► API Belasis (só GET)
                                                     │  até 15 leituras por vez (limite Belasis: 30/min)
                                                     ▼
                         belasis_registrar_resposta() grava e enfileira páginas/detalhes
```

- **Chave:** só nos segredos das Edge Functions do Supabase (a função usa `BELASIS_ACCESS_TOKEN` ou qualquer segredo cujo valor comece com `bpk_`). Nunca passa pelo n8n, pelo chat nem pelo repositório.
- **Só leitura:** a função faz apenas `GET`. Escrita no Belasis continua bloqueada (`belasis_modo` = `varredura`).
- **Rodadas:** completa agora e todo dia às 05:30 (Aracaju). Manual: `select public.belasis_iniciar_sync(120, 45);`
- **Desligar tudo:** `update config_bot set valor = '"desligado"' where chave = 'belasis_modo';`
- **Log:** cada GET fica em `belasis_chamadas` (rota, status, tempo — sem conteúdo).

| Tabela | O que guarda |
|---|---|
| `belasis_servicos` | catálogo: nome, preço de tabela, duração (min), ativo, agendamento online |
| `belasis_profissionais` | nome, apelido (Paty, Lari, Eli, Thais) |
| `belasis_profissional_servicos` | cadastro "quem faz o quê" do Belasis |
| `belasis_clientes` | primeiro nome, telefones normalizados, aniversário (sem CPF, e-mail ou endereço) |
| `belasis_agendamentos` | −120 a +45 dias: cliente, data, status, serviços, profissional, horários |
| `belasis_horarios_livres` | grade dos próximos 7 dias de funcionamento por profissional |

### Descobertas nos dados reais (10/10/2026)

- **4.266 clientes**, 4.029 com celular reconhecível; 140 serviços ativos (46 com agendamento online); 16 profissionais.
- **591 agendamentos em 30 dias**, 11% cancelados/faltas, 124 clientes voltaram 2+ vezes.
- A API devolve **duração em segundos** (a documentação diz minutos) — já corrigido.
- O cadastro "serviços por profissional" do Belasis não bate com a prática; o agente usa **quem de fato realizou** o serviço nos últimos 120 dias.
- Grade de horários de **1 em 1 hora**, das 9h às 17h.
- Preço real da escova: **R$ 80** (as conversas antigas citavam R$ 75).

## O que o agente ganhou

- **Memória da cliente** (`perfil_cliente_belasis`): reconhece pelo WhatsApp (com ou sem o 9º dígito), primeiro nome, últimos atendimentos com profissional, próximos horários, profissional e serviço mais frequentes, aniversário. Ex.: "sua última escova foi com o Adley, quer com ele de novo?"
- **Catálogo** (`consultar_servicos`): preço de tabela, duração e quem faz. Para química/coloração/luzes/selagem/alongamento, diz que o valor final é confirmado na avaliação/teste.
- Ainda **não** agenda direto: continua pré-agendando (equipe lança como NÃO CONFIRMADO).

## Publicar o painel na Vercel (a integração conectada aqui não tem permissão de escrita)

1. vercel.com → **Add New → Project → Import Git Repository** → `ampliize/Cabelosbykarol` (autorize o app da Vercel no GitHub se pedir).
2. **Root Directory:** `dashboard` · **Framework Preset:** Other · sem build command → **Deploy**.
3. Em **Settings → Git → Production Branch**, coloque `claude/whatsapp-belassis-automation-r101l7` (ou faça merge para `main`).
4. **Supabase → Authentication**:
   - **URL Configuration:** Site URL = URL da Vercel; adicione a mesma URL em *Redirect URLs*.
   - **Users → Invite user:** `tauaximenes1234@gmail.com` e `ampliize@gmail.com`.
5. Acesse a URL, digite o e-mail e clique no link (ou digite o código) que chegar.

Só e-mails em `painel_usuarios` veem dados; a chave publicável no `config.js` sozinha não lê nada.
