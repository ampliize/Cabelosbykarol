# API Belasis — Mapeamento para o agente

Fonte: documentação oficial (export de 30/09/2026). Especificação consolidada: [`belasis-api/openapi.json`](belasis-api/openapi.json) (pode importar no Postman/Insomnia).

## 1. Básico

| Item | Valor |
|---|---|
| Base URL | `https://api.belasis.com.br/api/v1` |
| Autenticação | Header `ACCESS-TOKEN: bpk_...` (gerar em Configurações → API; exige addon de API ativo) |
| **Rate limit** | **30 requisições/minuto por chave**. Excedeu → `429` sem corpo até virar o minuto |
| Paginação | `page`, `limit` (máx. 100) → resposta `{data, page, limit, total}` |
| Telefone | Enviar só dígitos com DDI: `5511987654321`. Retorno pode vir em outro formato (ex.: `11999998888`, `(11) 99999-8888`) |
| Datas/horas | `date` = `YYYY-MM-DD`, horas = `HH:MM` (fuso não documentado — assumir horário local do salão) |
| Erros de validação | `422` com array de strings (`["Cliente não pode ficar em branco"]`) |

Status de agendamento: `confirmed` · `unconfirmed` (padrão) · `disconfirm` (cancelado/no-show/remarcado) · `waiting` (cliente chegou).

## 2. Endpoints usados pelo agente

| Necessidade (TRD) | Endpoint real | Observação |
|---|---|---|
| Cliente por telefone | `GET /clients?search={digitos}` | `search` é parcial em nome, apelido, phone, cellphone e CPF. **Não existe filtro exato por telefone** → validar no n8n (ver §3.1) |
| Criar cliente nova | `POST /clients` `{name, phone, cellphone}` | `name` e `phone` obrigatórios |
| Histórico (serviço + profissional anteriores) | `GET /schedule_groups?client_id={id}&end_date={hoje}` | Cada agendamento tem `calendars[]` com `inventory_product_id`, `employee_id`, `start_hour`. Filtrar `status != disconfirm` |
| Próximos agendamentos | `GET /schedule_groups?client_id={id}&start_date={hoje}` | |
| Serviços, preço, duração | `GET /inventory/services?active=true` | `price_cents`, `duration` (min), **`available_to_online_scheduling`** |
| Profissionais | `GET /employees?active=true` | |
| Quem faz o quê | `GET /employees/{id}/services` | 1 chamada por profissional → cachear 24 h |
| Horários livres | `GET /employees/{id}/free_times?date=YYYY-MM-DD` | **1 profissional × 1 dia por chamada.** Retorna `[{hour:"08:00", label:"available"\|"unavailable"}]` |
| Agendar | `POST /schedule_groups` | Ver payload §4 |
| Cancelar | `PATCH /schedule_groups/{id}/cancel` | |
| Remarcar | criar novo (`POST`) **e depois** cancelar o antigo | O `PATCH` só altera hora, não a data; a própria doc orienta "cancela o antigo e cria novo" |
| Confirmar presença (fase 2, lembrete D-1) | `PATCH /schedule_groups/{id}/confirm` | |

Não usados: categorias/serviços (escrita), `DELETE` de cliente/agendamento, `waiting`.

## 3. Pontos de atenção e como resolvemos

### 3.1 Busca de cliente por telefone (sem filtro exato)
1. WhatsApp entrega `5511987654321` (às vezes sem o 9º dígito: `551187654321`).
2. Buscar `search=` com os **últimos 8 dígitos** (`87654321`), que batem com e sem 9º dígito, com e sem DDI.
3. No n8n, normalizar `phone` e `cellphone` de cada resultado (só dígitos, com DDI 55, com 9º dígito) e comparar com o número normalizado do WhatsApp.
4. 1 match → cliente. 0 → cliente nova. 2+ → pegar o de agendamento mais recente e registrar para revisão.
5. ⚠️ **Testar no dia 01/10** se o `search` encontra telefone salvo com máscara (`99999-8888`). Se não encontrar com 8 dígitos seguidos, tentar também `XXXX-XXXX`.

### 3.2 Rate limit de 30/min (o mais crítico)
Uma conversa pode gastar várias chamadas. Estratégia:
- **Um único sub-workflow `Belasis · Request`** faz todas as chamadas: limitador de vazão (token bucket no Supabase, 25/min para deixar folga), retry em `429` esperando a virada do minuto, log.
- **Cache no Supabase:** serviços e profissionais/serviços por profissional (24 h), cliente por telefone (30 min), histórico (30 min), `free_times` (2 min).
- **Busca de horários econômica:** consultar dia a dia a partir da data pedida e **parar ao achar 3 opções** (normalmente 1–3 chamadas). Sem profissional definida: no máx. 3 profissionais × 2 dias.
- Chave de API exclusiva para o bot (não compartilhar com outras integrações), se o Belasis permitir mais de uma.
- Estimativa: conversa de agendamento completa ≈ 4–8 chamadas → comporta ~3–6 agendamentos simultâneos por minuto; para um salão, suficiente.

### 3.3 `free_times` não considera a duração do serviço
Retorna a grade de horários (granularidade a confirmar, ex.: 15/30 min). O sub-workflow precisa verificar que **todos os slots consecutivos** cobrindo a `duration` do serviço estão `available` (ex.: progressiva de 180 min a partir das 09:00 → 09:00…11:30 livres).

### 3.4 Sem proteção documentada contra conflito
Não está documentado se o `POST` rejeita horário ocupado. Por isso `agendar_horario` **revalida** com `free_times` imediatamente antes do `POST`.

### 3.5 Serviços que o bot pode agendar
Usar `available_to_online_scheduling = true` como lista de serviços que o bot agenda sozinho. Os demais (ex.: coloração complexa) → informa e transfere para humano. Assim a Karol controla isso **dentro do próprio Belasis**, sem mexer no bot.

### 3.6 Sem webhooks
A API não envia eventos. Consequências: cache curto de horários e revalidação antes de escrever; lembretes (fase 2) por cron consultando `schedule_groups` do dia seguinte.

## 4. Payload de agendamento

```json
POST /api/v1/schedule_groups
{
  "client_id": 123,
  "date": "2026-10-04",
  "status": "confirmed",
  "observation": "Agendado pelo assistente WhatsApp (conversa <conversa_id>)",
  "calendars_attributes": [
    {
      "inventory_product_id": 45,
      "employee_id": 7,
      "start_hour": "09:00",
      "end_hour": "12:00",
      "reminder": true
    }
  ]
}
```

- `end_hour` = `start_hour` + `duration` do serviço.
- `status`: `confirmed`, porque a cliente confirmou no chat (**validar com a Karol**; alternativa `unconfirmed`).
- `observation` identifica que veio do bot → auditoria e filtro no Belasis.

## 5. Mapeamento final das ferramentas do agente

| Ferramenta | Chamadas Belasis |
|---|---|
| *(contexto, antes do agente)* | `GET /clients?search=` → `GET /schedule_groups?client_id=` (passado + futuro) |
| `buscar_servicos` | cache de `GET /inventory/services` + `GET /employees` + `GET /employees/{id}/services` |
| `consultar_horarios` | `GET /employees/{id}/free_times?date=` (dia a dia, até 3 opções) |
| `agendar_horario` | `free_times` (revalida) → [`POST /clients` se nova] → `POST /schedule_groups` |
| `alterar_agendamento` | cancelar: `PATCH /{id}/cancel` · remarcar: `free_times` → `POST` novo → `PATCH /{antigo}/cancel` |
| `consultar_base_conhecimento` | — (Supabase) |
| `transferir_para_humano` | — |

## 6. Teste de fumaça

`scripts/belasis-smoke.sh`: só leitura, valida chave, serviços, profissionais, horários livres e busca de cliente por telefone. Ver instruções no próprio script.
