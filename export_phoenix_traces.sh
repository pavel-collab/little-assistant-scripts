#!/usr/bin/env bash
# Export traces from Phoenix using only curl.
# Requires: curl (+ optionally jq for pretty JSON)
#
# Usage:
#   ./export_phoenix_traces.sh
#   ./export_phoenix_traces.sh --url http://host:6006 --project default
#   ./export_phoenix_traces.sh --list-projects
#   ./export_phoenix_traces.sh --since 2024-01-01 --until 2024-12-31

set -euo pipefail

PHOENIX_URL="http://localhost:6006"
PROJECT=""
SINCE=""
UNTIL=""
LIMIT=""
LIST_PROJECTS=0
OUTPUT=""

# ── parse args ────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)        PHOENIX_URL="$2"; shift 2 ;;
        --project)    PROJECT="$2";     shift 2 ;;
        --since)      SINCE="$2";       shift 2 ;;
        --until)      UNTIL="$2";       shift 2 ;;
        --limit)      LIMIT="$2";       shift 2 ;;
        -o|--output)  OUTPUT="$2";      shift 2 ;;
        --list-projects) LIST_PROJECTS=1; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PHOENIX_URL="${PHOENIX_URL%/}"

# ── list projects ─────────────────────────────────────────────────────────────
if [[ "$LIST_PROJECTS" -eq 1 ]]; then
    curl -sf "$PHOENIX_URL/v1/projects" | \
        (command -v jq &>/dev/null && jq -r '.data[].name' || cat)
    exit 0
fi

# ── resolve project ───────────────────────────────────────────────────────────
if [[ -z "$PROJECT" ]]; then
    if command -v jq &>/dev/null; then
        PROJECT=$(curl -sf "$PHOENIX_URL/v1/projects" | jq -r '.data[0].name')
    else
        # crude extraction without jq
        PROJECT=$(curl -sf "$PHOENIX_URL/v1/projects" | grep -o '"name":"[^"]*"' | head -1 | cut -d'"' -f4)
    fi
    echo "Using project: $PROJECT"
fi

# ── build query string ────────────────────────────────────────────────────────
PARAMS="project_identifier=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PROJECT" 2>/dev/null || printf '%s' "$PROJECT" | sed 's/ /%20/g')"
[[ -n "$SINCE" ]] && PARAMS="$PARAMS&start_time=$SINCE"
[[ -n "$UNTIL" ]] && PARAMS="$PARAMS&end_time=$UNTIL"

# ── output file ───────────────────────────────────────────────────────────────
TS=$(date +%Y%m%d_%H%M%S)
SAFE_PROJECT=$(echo "$PROJECT" | tr '/' '_')
[[ -z "$OUTPUT" ]] && OUTPUT="phoenix_traces_${SAFE_PROJECT}_${TS}.json"

# ── paginated fetch ───────────────────────────────────────────────────────────
CURSOR=""
ALL_SPANS="[]"
COUNT=0

while true; do
    QUERY="$PARAMS"
    [[ -n "$CURSOR" ]] && QUERY="$QUERY&cursor=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$CURSOR" 2>/dev/null || echo "$CURSOR")"

    RESPONSE=$(curl -sf "$PHOENIX_URL/v1/spans?$QUERY")

    if command -v jq &>/dev/null; then
        BATCH=$(echo "$RESPONSE" | jq '.data')
        BATCH_COUNT=$(echo "$BATCH" | jq 'length')
        NEXT_CURSOR=$(echo "$RESPONSE" | jq -r '.next_cursor // .meta.next_cursor // empty')
        ALL_SPANS=$(printf '%s\n%s' "$ALL_SPANS" "$BATCH" | \
            python3 -c "import json,sys; a,b=sys.stdin.read().split('\n',1); print(json.dumps(json.loads(a)+json.loads(b)))")
    else
        # without jq: just collect raw response pages into a file
        echo "$RESPONSE" >> "${OUTPUT}.pages"
        BATCH_COUNT=$(echo "$RESPONSE" | grep -o '"span_id"' | wc -l | tr -d ' ')
        NEXT_CURSOR=$(echo "$RESPONSE" | grep -o '"next_cursor":"[^"]*"' | cut -d'"' -f4)
    fi

    COUNT=$((COUNT + BATCH_COUNT))
    echo "  fetched $COUNT spans..."

    [[ -n "$LIMIT" ]] && [[ "$COUNT" -ge "$LIMIT" ]] && break
    [[ -z "$NEXT_CURSOR" ]] && break
    CURSOR="$NEXT_CURSOR"
done

# ── save ─────────────────────────────────────────────────────────────────────
if command -v jq &>/dev/null; then
    echo "$ALL_SPANS" | jq . > "$OUTPUT"
else
    # merge pages: wrap each raw response as array of pages
    echo "[" > "$OUTPUT"
    first=1
    while IFS= read -r line; do
        [[ "$first" -eq 0 ]] && echo "," >> "$OUTPUT"
        echo "$line" >> "$OUTPUT"
        first=0
    done < "${OUTPUT}.pages"
    echo "]" >> "$OUTPUT"
    rm -f "${OUTPUT}.pages"
fi

echo "Saved → $(pwd)/$OUTPUT  ($COUNT spans)"
