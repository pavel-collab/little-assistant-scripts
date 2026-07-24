#!/usr/bin/env bash
set -euo pipefail

API_KEY="sk-"

key_info=$(curl -sS https://openrouter.ai/api/v1/key \
  -H "Authorization: Bearer ${API_KEY}")

credits_info=$(curl -sS https://openrouter.ai/api/v1/credits \
  -H "Authorization: Bearer ${API_KEY}")

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
    remaining_usd:     ((.data.total_credits // 0) - (.data.total_usage // 0))
  }'
else
  echo "=== Key info ==="
  echo "$key_info"
  echo
  echo "=== Account credits ==="
  echo "$credits_info"
fi
