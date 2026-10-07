# Cabelos by Karol — Agente de IA no WhatsApp integrado ao Belasis

Automação de atendimento no WhatsApp do salão: responde dúvidas, identifica a cliente pelo telefone no Belasis, sugere horários (inclusive com a mesma profissional do último atendimento), agenda/remarca com confirmação e transfere para a equipe quando necessário.

Go-live alvo: **08/10/2026**.

## Documentos

1. [PRD — produto](docs/01-PRD.md)
2. [TRD — especificação técnica](docs/02-TRD.md)
3. [Arquitetura](docs/03-ARQUITETURA.md)
4. [Plano de entrega e pendências](docs/04-PLANO-DE-ENTREGA.md)
5. [API Belasis — mapeamento](docs/05-BELASIS-API.md) · [OpenAPI](docs/belasis-api/openapi.json)
6. [Banco de dados (Supabase)](docs/06-BANCO-DE-DADOS.md) · [migrations](supabase/migrations)
7. [Dashboard](dashboard/README.md) — demo: `dashboard/index.html?demo=1`
8. [Workflows n8n](docs/07-N8N-WORKFLOWS.md)
9. [Belasis — conexão segura e varredura](docs/08-BELASIS-CONEXAO-SEGURA.md)

## Teste rápido da API Belasis

```bash
export BELASIS_TOKEN="bpk_..."   # nunca commitar
./scripts/belasis-smoke.sh 5511987654321 2026-10-02
```

## Stack

n8n · OpenAI · Supabase · API Belasis · WhatsApp via Evolution API (não oficial, uso responsável — ver TRD §2.1) · Dashboard na Vercel
