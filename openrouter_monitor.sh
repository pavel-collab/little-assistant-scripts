#!/usr/bin/env bash
# TUI-монитор OpenRouter: лимит ключа, кредиты аккаунта, скорость расхода
# и (при наличии management-ключа) потребление токенов за сегодня.
#
# Использование:
#   ./openrouter_monitor.sh [-i секунды] [-a секунды]
#     -i  период опроса /key и /credits (по умолчанию 5)
#     -a  период опроса /activity для токенов (по умолчанию 60)
#
# Переменные окружения:
#   OPENROUTER_API_KEY   ключ для мониторинга; если не задан — берётся из check_openrouter_key.sh
#   OPENROUTER_MGMT_KEY  management-ключ; нужен только для статистики токенов (/api/v1/activity)
#
# Клавиши: q — выход, r — обновить сейчас.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="https://openrouter.ai/api/v1"
INTERVAL=5
ACTIVITY_INTERVAL=60
SPARK_LEN=40

while getopts "i:a:h" opt; do
  case "$opt" in
    i) INTERVAL="$OPTARG" ;;
    a) ACTIVITY_INTERVAL="$OPTARG" ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "Нужен jq: brew install jq" >&2; exit 1; }

API_KEY="${OPENROUTER_API_KEY:-}"
if [[ -z "$API_KEY" && -f "$SCRIPT_DIR/check_openrouter_key.sh" ]]; then
  API_KEY=$(sed -n 's/^API_KEY="\(.*\)"$/\1/p' "$SCRIPT_DIR/check_openrouter_key.sh")
fi
[[ -n "$API_KEY" ]] || { echo "Задайте OPENROUTER_API_KEY" >&2; exit 1; }
MGMT_KEY="${OPENROUTER_MGMT_KEY:-}"

# --- оформление -------------------------------------------------------------
ESC=$'\033'
B="${ESC}[1m"; D="${ESC}[2m"; R="${ESC}[0m"
RED="${ESC}[31m"; GRN="${ESC}[32m"; YEL="${ESC}[33m"; CYN="${ESC}[36m"
EL="${ESC}[K"
SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

cleanup() {
  printf '%s' "${ESC}[?25h${ESC}[?1049l"
  stty echo 2>/dev/null
  exit 0
}
trap cleanup INT TERM EXIT
printf '%s' "${ESC}[?1049h${ESC}[?25l"
stty -echo 2>/dev/null

# fetch URL KEY -> печатает тело; код возврата 0 только при HTTP 200
fetch() {
  local out code
  out=$(curl -sS --max-time 10 -w $'\n%{http_code}' "$1" -H "Authorization: Bearer $2" 2>&1) || { printf '%s' "$out"; return 1; }
  code="${out##*$'\n'}"
  out="${out%$'\n'*}"
  printf '%s' "$out"
  [[ "$code" == 200 ]]
}

calc() { awk "BEGIN { printf \"%.10g\", ($1) }"; }
money() { awk -v v="$1" 'BEGIN { if (v == "" || v == "null") print "—"; else printf "$%.4f", v }'; }
fmt_int() { awk -v v="$1" 'BEGIN { s = sprintf("%d", v); r = ""; while (length(s) > 3) { r = " " substr(s, length(s) - 2) r; s = substr(s, 1, length(s) - 3) } print s r }'; }

# bar ДОЛЯ_ОСТАТКА(0..1) ШИРИНА — цвет по остатку
bar() {
  local frac="$1" width="$2" filled color i s=""
  filled=$(awk -v f="$frac" -v w="$width" 'BEGIN { if (f < 0) f = 0; if (f > 1) f = 1; printf "%d", f * w + 0.5 }')
  color=$(awk -v f="$frac" -v g="$GRN" -v y="$YEL" -v r="$RED" 'BEGIN { print (f > 0.5 ? g : (f > 0.2 ? y : r)) }')
  for ((i = 0; i < width; i++)); do
    if ((i < filled)); then s+="█"; else s+="░"; fi
  done
  printf '%s%s%s' "$color" "$s" "$R"
}

sparkline() {
  local max s="" v idx
  (( ${#SAMPLES[@]} == 0 )) && { printf '%s' "${D}нет данных${R}"; return; }
  max=$(printf '%s\n' "${SAMPLES[@]}" | awk 'BEGIN { m = 0 } $1 > m { m = $1 } END { print m }')
  for v in "${SAMPLES[@]}"; do
    idx=$(awk -v v="$v" -v m="$max" 'BEGIN { if (m <= 0) print 0; else { i = int(v / m * 7 + 0.5); print (i > 7 ? 7 : i) } }')
    s+="${SPARK[$idx]}"
  done
  printf '%s' "$CYN$s$R"
}

duration() {
  awk -v s="$1" 'BEGIN { s = int(s); d = int(s / 86400); h = int(s % 86400 / 3600); m = int(s % 3600 / 60);
    if (d > 0) printf "%dд %dч", d, h; else if (h > 0) printf "%dч %dм", h, m; else printf "%dм %dс", m, s % 60 }'
}

# --- состояние --------------------------------------------------------------
KEY_JSON=""; CREDITS_JSON=""; ACTIVITY_JSON=""
KEY_ERR=""; CREDITS_ERR=""; ACTIVITY_ERR=""
START_TS=$(date +%s); START_USAGE=""
PREV_TS=""; PREV_USAGE=""; RATE_NOW=0
SAMPLES=()
LAST_ACTIVITY=0; LAST_UPDATE="—"

poll() {
  local body now usage delta dt
  if body=$(fetch "$API/key" "$API_KEY"); then KEY_JSON="$body"; KEY_ERR=""; else KEY_ERR="$body"; fi
  if body=$(fetch "$API/credits" "$API_KEY"); then CREDITS_JSON="$body"; CREDITS_ERR=""; else CREDITS_ERR="$body"; fi

  now=$(date +%s)
  if [[ -n "$MGMT_KEY" ]] && (( now - LAST_ACTIVITY >= ACTIVITY_INTERVAL )); then
    if body=$(fetch "$API/activity" "$MGMT_KEY"); then ACTIVITY_JSON="$body"; ACTIVITY_ERR=""; else ACTIVITY_ERR="$body"; fi
    LAST_ACTIVITY=$now
  fi

  if [[ -z "$KEY_ERR" && -n "$KEY_JSON" ]]; then
    usage=$(jq -r '.data.usage // 0' <<<"$KEY_JSON")
    # разные узлы API иногда отдают чуть устаревшее значение — usage не должен убывать
    [[ -n "$PREV_USAGE" ]] && usage=$(calc "$usage > $PREV_USAGE ? $usage : $PREV_USAGE")
    [[ -z "$START_USAGE" ]] && START_USAGE="$usage"
    if [[ -n "$PREV_USAGE" ]]; then
      delta=$(calc "($usage - $PREV_USAGE) < 0 ? 0 : $usage - $PREV_USAGE")
      dt=$(( now - PREV_TS )); (( dt < 1 )) && dt=1
      RATE_NOW=$(calc "$delta / $dt * 60")
      SAMPLES+=("$delta")
      (( ${#SAMPLES[@]} > SPARK_LEN )) && SAMPLES=("${SAMPLES[@]:1}")
    fi
    PREV_USAGE="$usage"; PREV_TS=$now
  fi
  LAST_UPDATE=$(date '+%H:%M:%S')
}

render() {
  local cols out="" w label limit remaining reset usage ud uw um free frac
  local tc tu rem session elapsed rate_avg eta
  cols=$(tput cols 2>/dev/null || echo 80)
  w=$(( cols - 30 )); (( w > 50 )) && w=50; (( w < 10 )) && w=10

  line() { out+="$1${EL}"$'\n'; }

  line "${B}OpenRouter monitor${R}  ${D}обновлено ${LAST_UPDATE} · опрос каждые ${INTERVAL}с · q — выход, r — обновить${R}"
  line ""

  # --- ключ
  line "${B}${CYN}■ Ключ${R}"
  if [[ -n "$KEY_JSON" ]]; then
    IFS=$'\t' read -r label limit remaining reset usage ud uw um free < <(jq -r '.data | [
      .label, (.limit // "null"), (.limit_remaining // "null"), (.limit_reset // "—"),
      .usage, .usage_daily, .usage_weekly, .usage_monthly, .is_free_tier] | @tsv' <<<"$KEY_JSON")
    line "  Метка:          $label   ${D}free tier: $free${R}"
    if [[ "$limit" == "null" ]]; then
      line "  Лимит ключа:    ${D}не задан (ограничен только кредитами аккаунта)${R}"
    else
      frac=$(calc "$limit > 0 ? $remaining / $limit : 0")
      line "  Лимит ключа:    $(bar "$frac" "$w") ${B}$(money "$remaining")${R} из $(money "$limit")  ${D}сброс: $reset${R}"
    fi
    line "  Расход:         сегодня ${B}$(money "$ud")${R} · неделя $(money "$uw") · месяц $(money "$um") · всего $(money "$usage")"
  fi
  [[ -n "$KEY_ERR" ]] && line "  ${RED}Ошибка /key: ${KEY_ERR:0:$((cols - 16))}${R}"
  line ""

  # --- кредиты
  line "${B}${CYN}■ Кредиты аккаунта${R}"
  if [[ -n "$CREDITS_JSON" ]]; then
    IFS=$'\t' read -r tc tu < <(jq -r '.data | [.total_credits // 0, .total_usage // 0] | @tsv' <<<"$CREDITS_JSON")
    rem=$(calc "$tc - $tu")
    frac=$(calc "$tc > 0 ? $rem / $tc : 0")
    line "  Остаток:        $(bar "$frac" "$w") ${B}$(money "$rem")${R} из $(money "$tc")"
    line "  Использовано:   $(money "$tu")"
  fi
  [[ -n "$CREDITS_ERR" ]] && line "  ${RED}Ошибка /credits: ${CREDITS_ERR:0:$((cols - 20))}${R}"
  line ""

  # --- скорость в реальном времени
  line "${B}${CYN}■ Расход в реальном времени${R}  ${D}(по изменению usage между опросами)${R}"
  elapsed=$(( $(date +%s) - START_TS ))
  if [[ -n "$START_USAGE" && -n "$PREV_USAGE" ]]; then
    session=$(calc "$PREV_USAGE - $START_USAGE")
    rate_avg=$(calc "$elapsed > 0 ? $session / $elapsed * 3600 : 0")
    line "  За сессию:      ${B}$(money "$session")${R} за $(duration "$elapsed")  ${D}≈ $(money "$rate_avg")/ч${R}"
    line "  Сейчас:         ${B}$(money "$RATE_NOW")/мин${R}"
    line "  История:        $(sparkline)"
    # прогноз исчерпания по среднему темпу сессии
    rem="${rem:-}"
    if [[ -n "${limit:-}" && "${limit:-}" != "null" ]]; then rem="$remaining"; fi
    if [[ -n "$rem" ]] && awk -v r="$rate_avg" 'BEGIN { exit !(r > 0) }'; then
      eta=$(calc "$rem / $rate_avg * 3600")
      line "  Хватит на:      ~$(duration "$eta") ${D}при текущем среднем темпе${R}"
    fi
  fi
  line ""

  # --- токены
  line "${B}${CYN}■ Токены за сегодня${R}"
  if [[ -z "$MGMT_KEY" ]]; then
    line "  ${D}Недоступно: /api/v1/activity требует management-ключ.${R}"
    line "  ${D}Задайте OPENROUTER_MGMT_KEY, чтобы видеть запросы и токены по моделям.${R}"
  elif [[ -n "$ACTIVITY_JSON" ]]; then
    local today summary
    today=$(date -u +%Y-%m-%d)
    summary=$(jq -r --arg d "$today" '
      [.data[] | select((.date // "") | startswith($d))] as $t
      | ([$t[].requests // 0] | add // 0),
        ([$t[].prompt_tokens // 0] | add // 0),
        ([$t[].completion_tokens // 0] | add // 0),
        ([$t[].reasoning_tokens // 0] | add // 0),
        ($t | group_by(.model) | map({m: .[0].model,
            tok: ([.[] | (.prompt_tokens // 0) + (.completion_tokens // 0)] | add),
            req: ([.[].requests // 0] | add), usd: ([.[].usage // 0] | add)})
          | sort_by(-.tok) | .[:5][] | "\(.m)\t\(.req)\t\(.tok)\t\(.usd)")' <<<"$ACTIVITY_JSON" 2>/dev/null)
    local req pt ct rt
    { read -r req; read -r pt; read -r ct; read -r rt; } <<<"$summary"
    line "  Запросов: ${B}$(fmt_int "$req")${R}   prompt: ${B}$(fmt_int "$pt")${R}   completion: ${B}$(fmt_int "$ct")${R}   reasoning: $(fmt_int "$rt")"
    line "  ${D}Данные /activity агрегируются по дням (UTC) и обновляются с задержкой.${R}"
    local m r t u
    while IFS=$'\t' read -r m r t u; do
      [[ -z "$m" ]] && continue
      line "$(printf '  %-40.40s %6s req %14s tok  %s' "$m" "$(fmt_int "$r")" "$(fmt_int "$t")" "$(money "$u")")"
    done < <(tail -n +5 <<<"$summary")
  fi
  [[ -n "$ACTIVITY_ERR" ]] && line "  ${RED}Ошибка /activity: ${ACTIVITY_ERR:0:$((cols - 20))}${R}"

  printf '%s' "${ESC}[H${out}${ESC}[J"
}

# --- главный цикл -----------------------------------------------------------
while true; do
  poll
  render
  deadline=$(( $(date +%s) + INTERVAL ))
  while (( $(date +%s) < deadline )); do
    if read -rsn1 -t 1 key; then
      case "$key" in
        q|Q) exit 0 ;;
        r|R) break ;;
      esac
    fi
  done
done
