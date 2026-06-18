#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PPDM environment check and authentication
# Exports: PPDM_BASE_URL, PPDM_TOKEN
# ------------------------------------------------------------

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

log_info()  { log "INFO"  "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
  log_error "$@"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=curl-ssl.sh
source "${SCRIPT_DIR}/curl-ssl.sh"

normalize_ppdm_url() {
  local input="$1"
  local base

  base="$(echo "$input" | sed -E 's|^https?://||')"
  base="${base%/}"

  [[ -n "$base" ]] || die "PPDM host/URL cannot be empty"

  if [[ "$base" =~ :[0-9]+$ ]]; then
    printf 'https://%s\n' "$base"
  else
    printf 'https://%s:8443\n' "$base"
  fi
}

extract_api_error() {
  local body="$1"
  local message

  message="$(echo "$body" | jq -r '
    .message // .error // .errorMessage //
    (.errors[0].message // empty) //
    (.content[0].message // empty) //
    empty
  ' 2>/dev/null || true)"

  if [[ -n "$message" && "$message" != "null" ]]; then
    echo "$message"
  fi
}

authenticate() {
  local http_code body api_error payload response_file curl_error
  local -a curl_args

  log_info "Authenticating to PPDM at ${PPDM_BASE_URL}..."

  payload="$(jq -n \
    --arg username "$PPDM_USER" \
    --arg password "$PPDM_PASSWORD" \
    '{username: $username, password: $password}')" || die "Failed to build login payload"

  response_file="$(mktemp)"
  curl_error="$(mktemp)"

  curl_args=(
    -sS
    -o "$response_file"
    -w '%{http_code}'
    -X POST "${PPDM_BASE_URL}/api/v2/login"
    -H "Content-Type: application/json"
    -d "$payload"
  )
  append_curl_ssl_args curl_args

  if ! http_code="$(curl "${curl_args[@]}" 2>"$curl_error")"; then
    body="$(cat "$response_file" 2>/dev/null || true)"
    api_error="$(cat "$curl_error" 2>/dev/null || true)"
    rm -f "$response_file" "$curl_error"
    if [[ -n "$api_error" ]]; then
      die "Failed to reach PPDM at ${PPDM_BASE_URL}: ${api_error}"
    fi
    if [[ -n "$body" ]]; then
      die "Failed to reach PPDM at ${PPDM_BASE_URL}: ${body}"
    fi
    die "Failed to reach PPDM at ${PPDM_BASE_URL} (connection error)"
  fi

  rm -f "$curl_error"
  body="$(cat "$response_file")"
  rm -f "$response_file"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    die "Unexpected response from PPDM (missing HTTP status)"
  fi

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    PPDM_TOKEN="$(echo "$body" | jq -r '.access_token // empty')" || \
      die "Failed to parse authentication response (invalid JSON)"

    [[ -n "$PPDM_TOKEN" && "$PPDM_TOKEN" != "null" ]] || \
      die "Authentication succeeded (HTTP ${http_code}) but no access_token was returned"

    export PPDM_TOKEN
    log_info "Authentication successful (HTTP ${http_code})"
    return 0
  fi

  api_error="$(extract_api_error "$body")"
  if [[ -n "$api_error" ]]; then
    die "Authentication failed (HTTP ${http_code}): ${api_error}"
  fi

  if [[ -z "$body" ]]; then
    die "Authentication failed (HTTP ${http_code}): empty response body"
  fi

  die "Authentication failed (HTTP ${http_code})"
}

# ------------------------------------------------------------
# Requirements
# ------------------------------------------------------------
log_info "Checking required commands..."
need_cmd curl
need_cmd jq
log_info "Required commands available"

# ------------------------------------------------------------
# Step 0: Determine PPDM_BASE_URL
# Priority:
#   1) If PPDM_BASE_URL already provided → normalize it
#   2) Else use PPDM_HOST (prompt if missing)
# ------------------------------------------------------------
if [[ -n "${PPDM_BASE_URL:-}" ]]; then
  log_info "Normalizing provided PPDM_BASE_URL"
  PPDM_BASE_URL="$(normalize_ppdm_url "$PPDM_BASE_URL")"
else
  if [[ -z "${PPDM_HOST:-}" ]]; then
    read -rp "PPDM Host (FQDN or IP, no port): " PPDM_HOST
  else
    log_info "Using PPDM_HOST from environment"
  fi

  PPDM_BASE_URL="$(normalize_ppdm_url "$PPDM_HOST")"
fi

export PPDM_BASE_URL
log_info "Using PPDM_BASE_URL=${PPDM_BASE_URL}"

# ------------------------------------------------------------
# Prompt for credentials if not provided
# ------------------------------------------------------------
if [[ -z "${PPDM_USER:-}" ]]; then
  read -rp "PPDM Username: " PPDM_USER
else
  log_info "Using PPDM_USER from environment"
fi

[[ -n "$PPDM_USER" ]] || die "PPDM username cannot be empty"

if [[ -z "${PPDM_PASSWORD:-}" ]]; then
  read -rsp "PPDM Password: " PPDM_PASSWORD
  echo
else
  log_info "Using PPDM_PASSWORD from environment"
fi

[[ -n "$PPDM_PASSWORD" ]] || die "PPDM password cannot be empty"

# ------------------------------------------------------------
# Step 1: Authenticate
# ------------------------------------------------------------
authenticate

log_info "Environment ready: PPDM_BASE_URL and PPDM_TOKEN exported"
