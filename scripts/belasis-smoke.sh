#!/usr/bin/env bash
# Teste de fumaça da API Belasis — SOMENTE LEITURA (não cria nem altera nada).
#
# Uso:
#   export BELASIS_TOKEN="bpk_..."            # nunca commitar a chave
#   ./scripts/belasis-smoke.sh [telefone] [data]
#
#   telefone: número de uma cliente real, ex. 5511987654321 (testa a busca por telefone)
#   data:     YYYY-MM-DD para consultar horários livres (padrão: amanhã)
#
# Requer: curl, jq. Faz ~8 requisições (limite da API: 30/min).

set -euo pipefail

BASE="https://api.belasis.com.br/api/v1"
: "${BELASIS_TOKEN:?Defina BELASIS_TOKEN com a chave bpk_...}"
PHONE="${1:-}"
DATE="${2:-$(date -d tomorrow +%F 2>/dev/null || date -v+1d +%F)}"

api() {
  local path="$1" code body
  body=$(curl -sS -w '\n%{http_code}' -H "Content-Type: application/json" \
    -H "ACCESS-TOKEN: ${BELASIS_TOKEN}" "${BASE}${path}")
  code="${body##*$'\n'}"; body="${body%$'\n'*}"
  if [[ "$code" != 2* ]]; then
    echo "  ✗ GET ${path} → HTTP ${code} ${body}" >&2
    return 1
  fi
  echo "$body"
}

section() { printf '\n== %s\n' "$1"; }

section "1. Autenticação + serviços ativos"
services=$(api "/inventory/services?active=true&limit=100")
echo "$services" | jq -r '"  total: \(.total)"'
echo "$services" | jq -r '.data[] | "  [\(.id)] \(.description) — R$ \(.price_cents/100) — \(.duration // "?") min — online: \(.available_to_online_scheduling)"'

section "2. Profissionais ativos"
employees=$(api "/employees?active=true&limit=100")
echo "$employees" | jq -r '"  total: \(.total)"'
echo "  exemplo de registro: $(echo "$employees" | jq -c '.data[0] // {}')"
echo "$employees" | jq -r '.data[] | "  [\(.id)] \(.name // .nickname // "?")"'

first_emp=$(echo "$employees" | jq -r '.data[0].id // empty')
if [[ -n "$first_emp" ]]; then
  section "3. Serviços da profissional ${first_emp}"
  api "/employees/${first_emp}/services" | jq -r '.data[] | "  [\(.id)] \(.description)"'

  section "4. Horários livres da profissional ${first_emp} em ${DATE}"
  slots=$(api "/employees/${first_emp}/free_times?date=${DATE}")
  echo "$slots" | jq -r '"  slots: \(length) · disponíveis: \([.[] | select(.label=="available")] | length)"'
  echo "$slots" | jq -r '[.[] | select(.label=="available") | .hour] | "  livres: \(join(" "))"'
  echo "$slots" | jq -r '[.[0].hour, .[1].hour] | "  granularidade (2 primeiros): \(join(" → "))"'
fi

if [[ -n "$PHONE" ]]; then
  digits="${PHONE//[^0-9]/}"
  last8="${digits: -8}"
  masked="${last8:0:4}-${last8:4:4}"
  section "5. Busca de cliente por telefone (${digits})"
  for q in "$digits" "$last8" "$masked"; do
    res=$(api "/clients?search=${q}&limit=10") || continue
    echo "$res" | jq -r --arg q "$q" '"  search=\($q) → \(.total) resultado(s)"'
    echo "$res" | jq -r '.data[] | "     [\(.id)] \(.name) · phone=\(.phone // "-") · cell=\(.cellphone // "-")"'
  done

  client_id=$(api "/clients?search=${last8}&limit=1" | jq -r '.data[0].id // empty' || true)
  if [[ -n "$client_id" ]]; then
    section "6. Histórico da cliente ${client_id} (agendamentos até hoje)"
    api "/schedule_groups?client_id=${client_id}&end_date=$(date +%F)&limit=5" \
      | jq -r '.data[] | "  \(.date) [\(.status)] " + ([.calendars[]? | "serviço=\(.inventory_product_id) prof=\(.employee_id) \(.start_hour)-\(.end_hour)"] | join(" | "))'
  fi
fi

printf '\nOK — cole a saída acima (sem a chave) para validarmos formatos de telefone, granularidade e histórico.\n'
