#!/usr/bin/env bash
# =============================================================================
# gist-api Load & Validation Test Runner
#
# Usage:
#   ./tests/load-test.sh [ENV] [BASE_URL]
#
# Examples:
#   ./tests/load-test.sh               # default: dev environment, auto port-forward
#   ./tests/load-test.sh staging       # run against staging
#   ./tests/load-test.sh dev http://localhost:8888   # run against existing port-forward
#
# Prerequisites:
#   - kubectl configured and pointing at your minikube cluster
#   - hey  (brew install hey)
#   - jq   (brew install jq)
#
# What this script tests:
#   1. Smoke tests       — health check, valid user lookup
#   2. Validation tests  — invalid params, boundary values, malformed inputs
#   3. Error path tests  — 404, 422 responses
#   4. Load tests        — sustained traffic to generate Grafana metrics
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
ENV="${1:-dev}"
BASE_URL="${2:-}"
NAMESPACE="gist-api-${ENV}"
SERVICE="gist-api-${ENV}"
LOCAL_PORT=18080
PASS=0
FAIL=0
PF_PID=""

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
pass()   { echo -e "${GREEN}[PASS]${NC}  $*"; PASS=$((PASS+1)); }
fail()   { echo -e "${RED}[FAIL]${NC}  $*"; FAIL=$((FAIL+1)); }
header() { echo -e "\n${YELLOW}══════════════════════════════════════${NC}"; echo -e "${YELLOW} $*${NC}"; echo -e "${YELLOW}══════════════════════════════════════${NC}"; }

assert_status() {
  local label="$1" expected="$2" actual="$3" body="$4"
  if [ "$actual" -eq "$expected" ]; then
    pass "$label — got $actual"
  else
    fail "$label — expected $expected, got $actual | body: $body"
  fi
}

# assert_github_status accepts 200 (success) or 403 (rate limit) as valid.
# Unauthenticated GitHub API allows only 60 req/hour per IP.
assert_github_status() {
  local label="$1" actual="$2" body="$3"
  if [ "$actual" -eq 200 ]; then
    pass "$label — got 200"
  elif [ "$actual" -eq 403 ]; then
    echo -e "${YELLOW}[SKIP]${NC}  $label — GitHub rate limit hit (403). Add GITHUB_TOKEN to avoid this."
  else
    fail "$label — expected 200 (or 403 rate limit), got $actual | body: $body"
  fi
}

assert_json_field() {
  local label="$1" field="$2" expected="$3" body="$4"
  local actual
  actual=$(echo "$body" | jq -r "$field" 2>/dev/null || echo "PARSE_ERROR")
  if [ "$actual" = "$expected" ]; then
    pass "$label — $field = $actual"
  else
    fail "$label — expected $field=$expected, got $actual"
  fi
}

assert_json_valid() {
  local label="$1" body="$2"
  if echo "$body" | jq . >/dev/null 2>&1; then
    pass "$label — response is valid JSON"
  else
    fail "$label — response is NOT valid JSON: $body"
  fi
}

# ── Port-forward setup ────────────────────────────────────────────────────────
setup_port_forward() {
  log "Setting up port-forward: $SERVICE.$NAMESPACE -> localhost:$LOCAL_PORT"
  kubectl port-forward "svc/$SERVICE" -n "$NAMESPACE" "${LOCAL_PORT}:8080" &>/tmp/pf.log &
  PF_PID=$!
  sleep 3

  if ! kill -0 "$PF_PID" 2>/dev/null; then
    echo -e "${RED}ERROR: port-forward failed. Check kubectl access and that pod is running.${NC}"
    cat /tmp/pf.log
    exit 1
  fi
  log "Port-forward active (PID $PF_PID)"
}

cleanup() {
  if [ -n "$PF_PID" ] && kill -0 "$PF_PID" 2>/dev/null; then
    log "Cleaning up port-forward (PID $PF_PID)"
    kill "$PF_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   gist-api Test Runner               ║${NC}"
echo -e "${CYAN}║   Environment: ${ENV}                 ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"

# Set up or use provided URL
if [ -z "$BASE_URL" ]; then
  setup_port_forward
  BASE_URL="http://localhost:${LOCAL_PORT}"
fi
log "Target URL: $BASE_URL"

# ─────────────────────────────────────────────────────────────────────────────
header "1. SMOKE TESTS"
# ─────────────────────────────────────────────────────────────────────────────

# 1.1 Health check
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/health")
BODY=$(cat /tmp/body.txt)
assert_status "GET /health returns 200" 200 "$RESP" "$BODY"
assert_json_valid "GET /health response is JSON" "$BODY"
assert_json_field "GET /health status field" ".status" "ok" "$BODY"

# 1.2 Valid user with gists
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat")
BODY=$(cat /tmp/body.txt)
assert_github_status "GET /octocat" "$RESP" "$BODY"
assert_json_valid "GET /octocat response is JSON" "$BODY"
if [ "$RESP" -eq 200 ]; then
  assert_json_field "GET /octocat user field" ".user" "octocat" "$BODY"
  # 1.3 Pagination defaults
  assert_json_field "GET /octocat default page=1" ".page" "1" "$BODY"
  assert_json_field "GET /octocat default per_page=30" ".per_page" "30" "$BODY"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "2. PAGINATION TESTS"
# ─────────────────────────────────────────────────────────────────────────────

# 2.1 Custom page and per_page
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?page=2&per_page=10")
BODY=$(cat /tmp/body.txt)
assert_github_status "GET /octocat?page=2&per_page=10" "$RESP" "$BODY"
if [ "$RESP" -eq 200 ]; then
  assert_json_field "Custom page=2 reflected in response" ".page" "2" "$BODY"
  assert_json_field "Custom per_page=10 reflected in response" ".per_page" "10" "$BODY"
fi

# 2.2 Boundary: per_page=1
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?per_page=1")
BODY=$(cat /tmp/body.txt)
assert_github_status "GET /octocat?per_page=1 (min boundary)" "$RESP" "$BODY"

# 2.3 Boundary: per_page=100
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?per_page=100")
BODY=$(cat /tmp/body.txt)
assert_github_status "GET /octocat?per_page=100 (max boundary)" "$RESP" "$BODY"

# ─────────────────────────────────────────────────────────────────────────────
header "3. VALIDATION & MALFORMED INPUT TESTS"
# ─────────────────────────────────────────────────────────────────────────────

# 3.1 page=0 — below minimum
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?page=0")
BODY=$(cat /tmp/body.txt)
assert_status "GET /octocat?page=0 (invalid) returns 422" 422 "$RESP" "$BODY"
assert_json_valid "422 response is valid JSON (not a crash)" "$BODY"

# 3.2 per_page=101 — above maximum
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?per_page=101")
BODY=$(cat /tmp/body.txt)
assert_status "GET /octocat?per_page=101 (above max) returns 422" 422 "$RESP" "$BODY"
assert_json_valid "422 response is valid JSON (not a crash)" "$BODY"

# 3.3 Malformed param — page is a string, not an integer
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?page=abc")
BODY=$(cat /tmp/body.txt)
assert_status "GET /octocat?page=abc (non-integer) returns 422" 422 "$RESP" "$BODY"
assert_json_valid "Malformed page param returns valid JSON error" "$BODY"

# 3.4 Malformed param — per_page is a float
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?per_page=1.5")
BODY=$(cat /tmp/body.txt)
assert_status "GET /octocat?per_page=1.5 (float) returns 422" 422 "$RESP" "$BODY"
assert_json_valid "Malformed per_page float returns valid JSON error" "$BODY"

# 3.5 Malformed param — negative per_page
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat?per_page=-5")
BODY=$(cat /tmp/body.txt)
assert_status "GET /octocat?per_page=-5 (negative) returns 422" 422 "$RESP" "$BODY"

# 3.6 Malformed param — SQL injection attempt in username (URL-encoded)
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" --max-time 10 \
  "$BASE_URL/%27%3BDROP%20TABLE%20users%3B--") || true
BODY=$(cat /tmp/body.txt)
assert_json_valid "SQL injection in username returns valid JSON (not a crash)" "$BODY"

# 3.7 Malformed param — URL-encoded XSS attempt in username
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" \
  "$BASE_URL/%3Cscript%3Ealert(1)%3C%2Fscript%3E") || true
BODY=$(cat /tmp/body.txt)
assert_json_valid "XSS attempt in username returns valid JSON (not a crash)" "$BODY"

# 3.8 Malformed param — very long username (255 chars)
LONG_USER=$(python3 -c "print('a' * 255)")
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/$LONG_USER") || true
BODY=$(cat /tmp/body.txt)
assert_json_valid "255-char username returns valid JSON (not a crash)" "$BODY"

# 3.9 Malformed param — extra unknown query params (should be ignored)
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" \
  "$BASE_URL/octocat?page=1&unknown_param=xyz&injected=true")
BODY=$(cat /tmp/body.txt)
assert_github_status "Unknown query params ignored" "$RESP" "$BODY"

# 3.10 Non-existent user (404 when GitHub reachable, 403 when rate limited)
RESP=$(curl -s -o /tmp/body.txt -w "%{http_code}" \
  "$BASE_URL/this-user-does-not-exist-xyzabc123")
BODY=$(cat /tmp/body.txt)
if [ "$RESP" -eq 404 ]; then
  pass "Non-existent user returns 404 — got 404"
elif [ "$RESP" -eq 403 ]; then
  echo -e "${YELLOW}[SKIP]${NC}  Non-existent user 404 — GitHub rate limit active (403)"
else
  fail "Non-existent user — expected 404 (or 403 rate limit), got $RESP | body: $BODY"
fi
assert_json_valid "Non-existent user error response is valid JSON" "$BODY"

# ─────────────────────────────────────────────────────────────────────────────
header "4. RESPONSE STRUCTURE TESTS"
# ─────────────────────────────────────────────────────────────────────────────

RESP_CODE=$(curl -s -o /tmp/body.txt -w "%{http_code}" "$BASE_URL/octocat")
RESP=$(cat /tmp/body.txt)

if [ "$RESP_CODE" -eq 200 ]; then
  # 4.1 Confirm all required top-level fields are present
  for field in ".user" ".count" ".page" ".per_page" ".gists"; do
    VAL=$(echo "$RESP" | jq -r "$field" 2>/dev/null || echo "MISSING")
    if [ "$VAL" != "MISSING" ] && [ "$VAL" != "null" ]; then
      pass "Response contains field: $field"
    else
      fail "Response missing field: $field"
    fi
  done

  # 4.2 Each gist has required fields
  GIST_COUNT=$(echo "$RESP" | jq '.gists | length')
  if [ "$GIST_COUNT" -gt 0 ]; then
    for field in ".id" ".description" ".html_url" ".public" ".files"; do
      VAL=$(echo "$RESP" | jq -r ".gists[0]$field" 2>/dev/null || echo "MISSING")
      if [ "$VAL" != "MISSING" ] && [ "$VAL" != "null" ]; then
        pass "Gist[0] contains field: $field"
      else
        fail "Gist[0] missing field: $field"
      fi
    done
  else
    log "octocat has 0 gists — skipping gist field checks"
  fi
else
  echo -e "${YELLOW}[SKIP]${NC}  Response structure checks skipped — GitHub rate limit active"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "5. LOAD TESTS  (generates Grafana metrics)"
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v hey &>/dev/null; then
  echo -e "${YELLOW}[SKIP] 'hey' not installed. Run: brew install hey${NC}"
else

  log "Phase 1 — /health burst (1000 req, 50 concurrent)"
  hey -n 1000 -c 50 "$BASE_URL/health" 2>&1 \
    | grep -E "Requests/sec:|Average:|Status code" || true

  log "Phase 2 — /octocat lookup (50 req, 5 concurrent)"
  hey -n 50 -c 5 "$BASE_URL/octocat" 2>&1 \
    | grep -E "Requests/sec:|Average:|Status code" || true

  log "Phase 3 — /health sustained (30 seconds, 20 concurrent)"
  hey -z 30s -c 20 "$BASE_URL/health" 2>&1 \
    | grep -E "Requests/sec:|Average:|Status code" || true

  log "Phase 4 — mixed endpoints (invalid + valid, 20 concurrent)"
  for url in \
    "$BASE_URL/octocat?page=0" \
    "$BASE_URL/octocat?per_page=101" \
    "$BASE_URL/octocat?page=abc" \
    "$BASE_URL/health" \
    "$BASE_URL/octocat"; do
    hey -n 20 -c 5 "$url" 2>&1 | grep "Status code" | sed "s|^|  $url → |" || true
  done

fi

# ─────────────────────────────────────────────────────────────────────────────
header "RESULTS"
# ─────────────────────────────────────────────────────────────────────────────
TOTAL=$((PASS + FAIL))
echo ""
echo -e "  ${GREEN}Passed: $PASS / $TOTAL${NC}"
if [ "$FAIL" -gt 0 ]; then
  echo -e "  ${RED}Failed: $FAIL / $TOTAL${NC}"
  echo ""
  exit 1
else
  echo -e "  ${GREEN}All tests passed ✓${NC}"
  echo ""
fi
