#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-"

API_KEY="${OPENROUTER_API_KEY:-$API_KEY}"
CREDITS_KEY="${OPENROUTER_MANAGEMENT_KEY:-$API_KEY}"

if ! command -v jq >/dev/null 2>&1; then
  echo "Ошибка: для проверки баланса требуется jq." >&2
  exit 1
fi

api_get() {
  local endpoint="$1" token="$2" response status body
  if ! response=$(curl -sS --connect-timeout 10 --max-time 30 \
    -w $'\n%{http_code}' "https://openrouter.ai/api/v1/$endpoint" \
    -H "Authorization: Bearer ${token}"); then
    echo "Ошибка соединения с OpenRouter ($endpoint). Баланс неизвестен." >&2
    return 1
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" != "200" ]]; then
    echo "Ошибка OpenRouter ($endpoint): HTTP $status. Баланс неизвестен." >&2
    if [[ "$endpoint" == "credits" && ( "$status" == "401" || "$status" == "403" ) ]]; then
      echo "Для /credits требуется действующий management key: задайте OPENROUTER_MANAGEMENT_KEY." >&2
    fi
    return 1
  fi
  if ! jq -e 'type == "object" and .error == null and (.data | type == "object")' \
    >/dev/null 2>&1 <<< "$body"; then
    echo "Некорректный ответ OpenRouter ($endpoint). Баланс неизвестен." >&2
    return 1
  fi
  printf '%s\n' "$body"
}

key_info=$(api_get key "$API_KEY")
credits_info=$(api_get credits "$CREDITS_KEY")

# Отсутствующие данные и ошибки API нельзя интерпретировать как нулевой баланс.
if ! jq -e '(.data.total_credits | type == "number") and
            (.data.total_usage | type == "number")' >/dev/null <<< "$credits_info"; then
  echo "Ответ OpenRouter не содержит числовых данных баланса. Баланс неизвестен." >&2
  exit 1
fi
if ! jq -e '.data.usage | type == "number"' >/dev/null <<< "$key_info"; then
  echo "Ответ OpenRouter не содержит расхода по ключу." >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  echo "=== Key info ==="
  echo "$key_info" | jq '{
    label:           .data.label,
    is_free_tier:    .data.is_free_tier,
    usage_usd:       .data.usage,
    key_limit_usd:   .data.limit,
    key_limit_left:  .data.limit_remaining
  }'

  echo
  echo "=== Account credits ==="
  echo "$credits_info" | jq '{
    total_credits_usd: .data.total_credits,
    total_usage_usd:   .data.total_usage,
    remaining_usd:     (.data.total_credits - .data.total_usage)
  }'
else
  echo "=== Key info ==="
  echo "$key_info"
  echo
  echo "=== Account credits ==="
  echo "$credits_info"
fi
