# Cabelos by Karol — Agente de IA no WhatsApp integrado ao Belasis

Agente de IA humanizado no WhatsApp do salão: responde dúvidas, identifica a cliente pelo telefone no Belasis, sugere horários (inclusive com a mesma profissional do último atendimento), agenda/remarca com confirmação e transfere para a equipe quando necessário.

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
9. [Belasis — conexão segura (última etapa)](docs/08-BELASIS-CONEXAO-SEGURA.md)
10. [Belasis — como funciona (pesquisa) e convivência no WhatsApp](docs/09-BELASIS-COMO-FUNCIONA.md)
11. [Respostas do cliente — o que foi configurado](docs/10-RESPOSTAS-DO-CLIENTE.md)
12. [Análise das conversas](docs/11-ANALISE-CONVERSAS.md)
13. **[Passo a passo para os testes](docs/12-PASSO-A-PASSO-TESTES.md)**
14. [Belasis → Supabase e publicação do painel](docs/13-BELASIS-SINCRONIZACAO-E-PAINEL.md)

## Teste rápido da API Belasis

```bash
export BELASIS_TOKEN="bpk_..."   # nunca commitar
./scripts/belasis-smoke.sh 5511987654321 2026-10-02
```

## Stack

n8n · OpenAI · Supabase · API Belasis · WhatsApp via Evolution API (não oficial, uso responsável — ver TRD §2.1) · Dashboard na Vercel
