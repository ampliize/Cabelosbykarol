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
- **Rodadas automáticas** (o Belasis não tem webhook, então o sistema confere sozinho):

| Rodada | Frequência | O que relê | Mudança aparece no agente em |
|---|---|---|---|
| `catalogo` | a cada 15 min | serviços (preço, duração, ativo, categoria) e profissionais | até ~15–20 min |
| `agenda` | a cada 10 min | agendamentos de −3 a +60 dias | até ~10–15 min |
| `completa` | todo dia 05:30 (Aracaju) | tudo: catálogo, categorias, quem faz o quê, 4.266 clientes, agenda de −365 a +60 dias, horários livres de 14 dias | dia seguinte |

  Manual: `select public.belasis_iniciar_sync('completa');` (ou `'catalogo'` / `'agenda'`).
- **Reflexo automático no agente:** o agente não guarda cópia própria; `consultar_servicos` e `perfil_cliente_belasis` leem as tabelas na hora. Novo profissional, preço alterado, serviço desativado ou agendamento cancelado entram sozinhos na próxima rodada.
- **O que some do Belasis some do agente:** ao fim de cada rodada sem erro (`belasis_finalizar_rodadas`), serviço/profissional que não veio mais fica `ativo = false` e agendamento apagado vira `removido`. Se alguma página falhar, nada é desativado naquela rodada (por segurança).
- **Histórico das rodadas:** `select tipo, iniciada_em, finalizada_em, resumo from belasis_rodadas order by iniciada_em desc limit 10;`
- **Desligar tudo:** `update config_bot set valor = '"desligado"' where chave = 'belasis_modo';`
- **Log:** cada GET fica em `belasis_chamadas` (rota, status, tempo — sem conteúdo).

| Tabela | O que guarda |
|---|---|
| `belasis_servicos` | catálogo: nome, preço de tabela, duração (min), ativo, agendamento online, favorito, categoria |
| `belasis_grupos` | categorias do catálogo |
| `belasis_profissionais` | nome, apelido do Belasis, profissão, ativo, apelido curto (Paty, Lari, Eli, Thais) |
| `belasis_profissional_servicos` | cadastro "quem faz o quê" do Belasis |
| `belasis_clientes` | primeiro nome, telefones normalizados, aniversário (sem CPF, e-mail ou endereço) |
| `belasis_agendamentos` | −365 a +60 dias: cliente, data, status, serviços, profissional, horários |
| `belasis_horarios_livres` | grade dos próximos 14 dias de funcionamento por profissional |
| `belasis_rodadas` | cada rodada de sincronização e seu resumo |

### Descobertas nos dados reais (10/10/2026)

- **4.266 clientes**, 4.029 com celular reconhecível; 140 serviços ativos (46 com agendamento online); 16 profissionais.
- **Rodada completa v2 (10/10/2026): 299 leituras, 0 erros.** 85 profissionais no histórico (16 ativas), 16 categorias, 6.948 agendamentos (out/2025 a dez/2026): **6.064 atendimentos em 12 meses, 1.156 clientes diferentes**.
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
