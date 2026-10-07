# Belasis — conexão segura, sem interferir na operação do salão

Objetivo: deixar tudo pronto e ligar o Belasis **em etapas**, cada uma reversível em segundos, começando por um raio-x **somente leitura** de como o sistema do salão está configurado.

## 1. Onde poderia haver interferência e como está travado

| Risco | Trava |
|---|---|
| Bot criar/alterar/cancelar agendamento sem querer | Escrita só existe no modo `escrita`. Fora dele, o banco recusa antes de a chamada sair do n8n (`autorizar_chamada_belasis`). Mesmo no modo `escrita`, só 3 rotas na lista branca (`POST /clients`, `POST /schedule_groups`, `PATCH /schedule_groups/{id}/cancel`). **DELETE nunca.** |
| Consumir a cota da API (30/min) e travar outra integração do salão | Limite próprio de **20/min** (`belasis_limite_por_minuto`), com espera automática na virada do minuto. Se o Belasis devolver 429, o resto do minuto fica bloqueado. |
| Disparar lembretes/mensagens automáticas do Belasis para clientes | Só acontece ao criar agendamento (modo `escrita`). Testar antes com uma cliente de teste. |
| Duplicar cadastro de cliente | `POST /clients` só no modo `escrita`. |
| Bot "roubar" um horário que a recepção está marcando | No modo `leitura` o bot nunca grava: cria um **pré-agendamento** e a equipe lança no Belasis. |
| Expor dados de clientes | O log (`belasis_chamadas`) guarda só método, rota, status e tempo, nunca o conteúdo. O relatório da varredura não tem nome nem telefone de cliente. |
| Algo dar errado | Botão de pânico: `update config_bot set valor = '"desligado"' where chave = 'belasis_modo';` corta todas as chamadas na hora. |

Todas as chamadas passam por um único workflow, **CBK · Belasis Request**. Nenhum outro workflow tem a credencial do Belasis.

## 2. Modos (`config_bot.belasis_modo`)

| Modo | O que acontece | O que o salão percebe |
|---|---|---|
| `desligado` (**atual**) | Nenhuma chamada | Nada |
| `varredura` | Só a varredura (GET). O agente não consulta | Nada (≈ 15–50 leituras, uma vez) |
| `leitura` | Agente consulta cliente, histórico e horários livres. Agendamento confirmado pela cliente vira **pré-agendamento** e a equipe recebe no WhatsApp para lançar | Avisos de pré-agendamento no WhatsApp do responsável |
| `escrita` | Agente agenda e cancela direto (só rotas da lista branca) | Agendamentos com a observação "Agendado pelo assistente WhatsApp" |

## 3. Etapas

### Etapa 1: varredura (somente leitura)
1. Criar no n8n a credencial **CBK Belasis API** (Header Auth, nome `ACCESS-TOKEN`, valor `bpk_...`). A chave fica só no n8n.
2. Trocar nos workflows **CBK · Belasis Request** e **CBK · Belasis Varredura** as credenciais automáticas pelas CBK.
3. `belasis_modo = 'varredura'`, rodar **CBK · Belasis Varredura** (1–3 min) e voltar para `desligado`.
4. Ler o relatório (`select relatorio from belasis_varreduras order by id desc limit 1`) e revisar com o cliente.

O relatório responde:

| Pergunta | Campo |
|---|---|
| A chave funciona? Algum erro ou 429? | `chamadas` |
| Quais serviços, preços e durações? Quais estão liberados para agendamento online? | `servicos` |
| Quem são as profissionais e o que cada uma faz? | `profissionais` |
| De quantos em quantos minutos é a grade? Que horas abre e fecha? Quão cheia está a agenda? | `horarios_livres` |
| Volume, status, dias e horários de pico, serviços mais feitos, % com vários serviços, % com lembrete | `agenda` (−30 a +30 dias) |
| Em que formato os telefones estão cadastrados? Quantas clientes não têm celular? | `clientes` (amostra de 100, sem dados pessoais) |
| Dá para achar a cliente pelos últimos 8 dígitos do WhatsApp? | `busca_telefone` |
| O que precisa ser ajustado antes de ligar o agente | `alertas` |

O catálogo (serviços, profissionais, quem faz o quê) fica salvo em `belasis_servicos`, `belasis_profissionais` e `belasis_profissional_servicos`, e o agente pode usá-lo sem chamar a API.

### Etapa 2: leitura (piloto)
O agente identifica a cliente, vê o histórico ("mesma profissional") e consulta horários livres. Quando a cliente confirma, chama `criar_pre_agendamento` e o responsável recebe:

> 📅 *Pré-agendamento — lançar no Belasis*
> 👤 Juliana · wa.me/55799…
> 📝 Lançar no Belasis: Progressiva com Ana — 09/10 (Sex) às 09:00 até 12:00
> Depois de lançar, confirme para a cliente pelo WhatsApp.

Quando a equipe responde a cliente, o bot pausa (regra dos 3 min). Fica nessa etapa até o salão confiar nas sugestões.

### Etapa 3: escrita
Só com aprovação da Karol. Antes, testar com uma cliente de teste e verificar se o Belasis manda mensagem automática ao criar agendamento.

## 4. Consultas úteis

```sql
-- relatório mais recente
select relatorio from belasis_varreduras order by id desc limit 1;

-- chamadas das últimas 24 h
select modo, metodo, rota, permitido, motivo_bloqueio, status_http, count(*), round(avg(duracao_ms)) ms
  from belasis_chamadas where criado_em > now() - interval '24 hours'
 group by 1,2,3,4,5,6 order by count(*) desc;

-- pré-agendamentos pendentes
select * from pre_agendamentos where estado = 'pendente' order by criado_em;
```

## 5. Arquivos

- Banco: `supabase/migrations/20261007090000_belasis_modo_seguro.sql` · teste `supabase/tests/belasis_modo.sql` (16/16)
- n8n: **CBK · Belasis Request** (`UgCDVa86CbsBwpwE`) · **CBK · Belasis Varredura** (`NDN0IRHvMJdO4wug`)
