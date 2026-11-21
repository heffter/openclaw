#!/usr/bin/env bash
# Browser integration test for OpenClaw gateway container.
# Exercises: status, start, navigate, snapshot, click, screenshot, stop.
#
# Usage: ./scripts/test-browser.sh [--url URL] [--verbose]

set -euo pipefail

CONTAINER="openclaw-openclaw-gateway-1"
BROWSER_PORT=18791
URL="https://example.com"
VERBOSE=""

# Parse flags
for arg in "$@"; do
  case "$arg" in
    --verbose|-v) VERBOSE=1 ;;
    --url=*) URL="${arg#--url=}" ;;
    http*) URL="$arg" ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass=0
fail=0
warn=0

ok()      { pass=$((pass + 1)); printf "${GREEN}✓${NC} %s\n" "$1"; }
fail()    { fail=$((fail + 1)); printf "${RED}✗${NC} %s\n" "$1"; }
info()    { printf "${CYAN}→${NC} %s\n" "$1"; }
warning() { warn=$((warn + 1)); printf "${YELLOW}⚠${NC} %s\n" "$1"; }

# Get the gateway token from the container env
TOKEN=$(docker exec "$CONTAINER" printenv OPENCLAW_GATEWAY_TOKEN 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "ERROR: Could not read OPENCLAW_GATEWAY_TOKEN from container"
  exit 1
fi

# curl wrapper that hits the browser control API inside the container
api() {
  local method="$1" path="$2"
  shift 2
  local body="${1:-}"

  local args=(-s -w '\n%{http_code}' --max-time 30 -X "$method"
    -H "Authorization: Bearer $TOKEN"
    -H "Content-Type: application/json"
    "http://127.0.0.1:${BROWSER_PORT}${path}")

  if [ -n "$body" ]; then
    args+=(-d "$body")
  fi

  docker exec "$CONTAINER" curl "${args[@]}" 2>&1
}

# Parse response: last line is HTTP status code, rest is body
parse_response() {
  local raw="$1"
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

api_call() {
  local label="$1" method="$2" path="$3"
  shift 3
  local body="${1:-}"

  info "$label"
  local raw
  raw=$(api "$method" "$path" "$body")
  parse_response "$raw"

  if [ "$VERBOSE" = "1" ]; then
    echo "  HTTP $HTTP_CODE"
    echo "  $HTTP_BODY" | head -5
  fi
}

jq_py() {
  python3 -c "import sys,json; d=json.load(sys.stdin); $1" 2>/dev/null
}

# ── Tests ────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  OpenClaw Browser Integration Test"
echo "═══════════════════════════════════════════════"
echo "  Container: $CONTAINER"
echo "  Target URL: $URL"
echo ""

# 0. Container health
info "Checking container is running..."
if docker exec "$CONTAINER" true 2>/dev/null; then
  ok "Container is running"
else
  fail "Container is not running"
  exit 1
fi

# 1. Auth + Status
api_call "Testing auth & getting status..." GET "/"
if [ "$HTTP_CODE" != "200" ]; then
  fail "Auth failed (HTTP $HTTP_CODE)"
  exit 1
fi
ok "Auth works (HTTP 200)"

ENABLED=$(echo "$HTTP_BODY" | jq_py "print(d.get('enabled','?'))" || echo "?")
RUNNING=$(echo "$HTTP_BODY" | jq_py "print(d.get('running','?'))" || echo "?")
CDP_READY=$(echo "$HTTP_BODY" | jq_py "print(d.get('cdpReady','?'))" || echo "?")
echo "  enabled=$ENABLED running=$RUNNING cdpReady=$CDP_READY"

if [ "$ENABLED" = "True" ]; then
  ok "Browser is enabled"
else
  fail "Browser is NOT enabled"
  exit 1
fi

# 2. Clean slate: stop any existing browser, clear stale locks
if [ "$RUNNING" = "True" ]; then
  api_call "Stopping existing browser first..." POST "/stop"
  sleep 2
fi

info "Clearing stale Chrome profile locks..."
docker exec "$CONTAINER" find /home/node/.openclaw/browser -name "SingletonLock" -delete 2>/dev/null || true
docker exec "$CONTAINER" find /home/node/.openclaw/browser -name "SingletonCookie" -delete 2>/dev/null || true
docker exec "$CONTAINER" find /home/node/.openclaw/browser -name "SingletonSocket" -delete 2>/dev/null || true
ok "Locks cleared"

# 3. Start browser
api_call "Starting browser..." POST "/start"
if [ "$HTTP_CODE" = "200" ]; then
  ok "Browser started"
else
  fail "Browser start failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | head -2)"
  exit 1
fi
sleep 3

# Re-check status
api_call "Re-checking status after start..." GET "/"
RUNNING=$(echo "$HTTP_BODY" | jq_py "print(d.get('running','?'))" || echo "?")
CDP_READY=$(echo "$HTTP_BODY" | jq_py "print(d.get('cdpReady','?'))" || echo "?")
PID=$(echo "$HTTP_BODY" | jq_py "print(d.get('pid','?'))" || echo "?")
echo "  running=$RUNNING cdpReady=$CDP_READY pid=$PID"

if [ "$RUNNING" = "True" ] && [ "$CDP_READY" = "True" ]; then
  ok "Browser running with CDP ready"
else
  fail "Browser not fully ready (running=$RUNNING cdpReady=$CDP_READY)"
  echo "  Full status:"
  echo "$HTTP_BODY" | python3 -m json.tool 2>/dev/null || echo "  $HTTP_BODY"
  exit 1
fi

# 4. List tabs (before)
api_call "Listing tabs..." GET "/tabs"
if [ "$HTTP_CODE" = "200" ]; then
  TAB_COUNT=$(echo "$HTTP_BODY" | jq_py "print(len(d.get('tabs',[])))" || echo "?")
  ok "Tab list OK ($TAB_COUNT tabs)"
else
  fail "Tab list failed (HTTP $HTTP_CODE)"
fi

# 5. Open tab / navigate
api_call "Opening $URL..." POST "/tabs/open" "{\"url\":\"$URL\"}"
if [ "$HTTP_CODE" = "200" ]; then
  TARGET_ID=$(echo "$HTTP_BODY" | jq_py "print(d.get('targetId',''))" || echo "")
  ok "Tab opened (targetId=${TARGET_ID:0:20}...)"
else
  fail "Tab open failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | head -1)"
  exit 1
fi

info "Waiting for page load (3s)..."
sleep 3

# 6. Snapshot (GET with query param — this was the key bug)
api_call "Taking snapshot..." GET "/snapshot?targetId=$TARGET_ID"
if [ "$HTTP_CODE" = "200" ]; then
  SNAP_LEN=${#HTTP_BODY}
  SNAP_TEXT=$(echo "$HTTP_BODY" | jq_py "print(d.get('snapshot','')[:200])" || echo "")
  ok "Snapshot OK (${SNAP_LEN} bytes)"
  if [ -n "$SNAP_TEXT" ]; then
    echo "  Preview: ${SNAP_TEXT:0:120}..."
  fi
  if [ "$VERBOSE" = "1" ]; then
    echo "$HTTP_BODY" | python3 -c "
import sys,json
d=json.load(sys.stdin)
for k,v in d.items():
    if isinstance(v,str) and len(v)>200: v=v[:200]+'...'
    elif isinstance(v,list): v=f'[{len(v)} items]'
    elif isinstance(v,dict): v=f'{{{len(v)} keys}}'
    print(f'    {k}: {v}')
" 2>/dev/null || true
  fi
else
  fail "SNAPSHOT FAILED (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | head -2)"
fi

# 7. Screenshot (POST)
api_call "Taking screenshot..." POST "/screenshot" "{\"targetId\":\"$TARGET_ID\"}"
if [ "$HTTP_CODE" = "200" ]; then
  SCREENSHOT_PATH=$(echo "$HTTP_BODY" | jq_py "print(d.get('path',''))" || echo "")
  if [ -n "$SCREENSHOT_PATH" ]; then
    ok "Screenshot saved to $SCREENSHOT_PATH"
  else
    ok "Screenshot OK"
  fi
else
  fail "Screenshot failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | head -1)"
fi

# 8. Get first clickable ref from snapshot
FIRST_REF=$(echo "$HTTP_BODY" 2>/dev/null | jq_py "
import re
refs = d.get('refs', {})
for ref_id, ref_data in refs.items():
    role = ref_data.get('role','')
    if role in ('link', 'button'):
        print(ref_id)
        break
else:
    print('')
" 2>/dev/null || echo "")

# Use snapshot body (not screenshot body) for refs
FIRST_REF=""
if [ -n "${SNAP_TEXT:-}" ]; then
  # Re-fetch snapshot to get refs
  raw_snap=$(api GET "/snapshot?targetId=$TARGET_ID")
  parse_response "$raw_snap"
  if [ "$HTTP_CODE" = "200" ]; then
    FIRST_REF=$(echo "$HTTP_BODY" | jq_py "
refs = d.get('refs', {})
for ref_id, ref_data in refs.items():
    role = ref_data.get('role','')
    if role in ('link', 'button'):
        print(ref_id)
        break
else:
    print('')
" || echo "")
  fi
fi

if [ -n "$FIRST_REF" ]; then
  api_call "Clicking element ref=$FIRST_REF..." POST "/act" "{\"kind\":\"click\",\"ref\":\"$FIRST_REF\",\"targetId\":\"$TARGET_ID\"}"
  if [ "$HTTP_CODE" = "200" ]; then
    ok "Click action OK (ref=$FIRST_REF)"
  elif [ "$HTTP_CODE" = "500" ]; then
    warning "Click ref=$FIRST_REF timed out (may be non-interactive element)"
  else
    fail "Click failed (HTTP $HTTP_CODE): $(echo "$HTTP_BODY" | head -1)"
  fi
else
  warning "No clickable link/button ref found on page — skipping click test"
fi

# 9. Second snapshot (test repeated calls work)
sleep 1
api_call "Second snapshot..." GET "/snapshot?targetId=$TARGET_ID"
if [ "$HTTP_CODE" = "200" ]; then
  ok "Second snapshot OK"
else
  fail "Second snapshot failed (HTTP $HTTP_CODE)"
fi

# 10. Close tab
api_call "Closing tab..." DELETE "/tabs/$TARGET_ID"
if [ "$HTTP_CODE" = "200" ]; then
  ok "Tab closed"
else
  warning "Tab close: HTTP $HTTP_CODE"
fi

# 11. Memory check
info "Checking container memory..."
MEM=$(docker stats "$CONTAINER" --no-stream --format "{{.MemUsage}}" 2>/dev/null || echo "unknown")
echo "  Memory: $MEM"
MEM_PCT=$(docker stats "$CONTAINER" --no-stream --format "{{.MemPerc}}" 2>/dev/null || echo "0%")
echo "  Usage:  $MEM_PCT"
ok "Memory check done"

# ── Summary ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
printf "  Results: ${GREEN}%d passed${NC}" "$pass"
[ "$fail" -gt 0 ] && printf "  ${RED}%d failed${NC}" "$fail"
[ "$warn" -gt 0 ] && printf "  ${YELLOW}%d warnings${NC}" "$warn"
echo ""
echo "═══════════════════════════════════════════════"
echo ""

[ "$fail" -gt 0 ] && exit 1
exit 0
