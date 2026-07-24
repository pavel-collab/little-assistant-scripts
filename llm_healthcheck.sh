#!/usr/bin/env bash
set -euo pipefail

OPENROUTER_API_KEY=sk-
MODEL="qwen/qwen3.5-35b-a3b"
PROMPT="Reply with a single word: pong"

if [[ "$OPENROUTER_API_KEY" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "ERROR: установите OPENROUTER_API_KEY (env-переменной или прямо в скрипте)." >&2
  exit 1
fi

echo "==> Проверка соединения с openrouter.ai..."
if ! curl -fsS -o /dev/null -w "HTTP %{http_code} | время: %{time_total}s\n" \
    https://openrouter.ai/api/v1/models; then
  echo "ERROR: не удалось достучаться до openrouter.ai. Проверь прокси/сеть." >&2
  exit 2
fi

echo
echo "==> Запрос к модели ${MODEL}..."
RESPONSE=$(curl -sS -w "\n__HTTP_STATUS__:%{http_code}\n__TIME__:%{time_total}\n" \
  https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
  -H "Content-Type: application/json" \
  -d @- <<EOF
{
  "model": "${MODEL}",
  "messages": [
    {"role": "user", "content": "${PROMPT}"}
  ],
  "max_tokens": 20
}
EOF
)

HTTP_STATUS=$(echo "$RESPONSE" | sed -n 's/^__HTTP_STATUS__://p')
TIME_TOTAL=$(echo "$RESPONSE" | sed -n 's/^__TIME__://p')
BODY=$(echo "$RESPONSE" | sed '/^__HTTP_STATUS__:/,$d')

echo "HTTP: ${HTTP_STATUS} | время: ${TIME_TOTAL}s"
echo "--- Ответ ---"
echo "$BODY"
echo "-------------"

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "ERROR: получили статус ${HTTP_STATUS}, ожидается 200." >&2
  exit 3
fi

if command -v jq >/dev/null 2>&1; then
  CONTENT=$(echo "$BODY" | jq -r '.choices[0].message.content // empty')
  if [[ -n "$CONTENT" ]]; then
    echo "==> Содержимое ответа модели: ${CONTENT}"
    echo "OK: healthcheck успешен."
    exit 0
  fi
  echo "WARN: тело ответа без поля choices[0].message.content (jq)." >&2
  exit 4
else
  echo "(jq не установлен — пропускаю парсинг JSON; смотри тело выше)"
fi
