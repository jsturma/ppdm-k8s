#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PPDM environment check and authentication
#
# Writes PPDM_BASE_URL and PPDM_TOKEN to PPDM_ENV_FILE (default:
# .ppdm-env.cfg in this directory) for use by other scripts.
# An existing env file is removed and recreated on each run.
# ------------------------------------------------------------

log() {
  local level="$1"
  shift
  printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >&2
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
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
# shellcheck source=ppdm-env-cfg.sh
source "${SCRIPT_DIR}/ppdm-env-cfg.sh"

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

configure_ppdm_tls() {
  if [[ -n "${PPDM_CA_CERT:-}" || -n "${CURL_CA_CERT:-}" ]]; then
    log_info "Using custom CA certificate from environment"
    return 0
  fi

  if [[ -n "${PPDM_CURL_INSECURE:-}" ]]; then
    if resolve_curl_insecure; then
      export PPDM_CURL_INSECURE=true
      log_warn "Using PPDM_CURL_INSECURE=true from environment"
    else
      log_info "TLS verification enabled (PPDM_CURL_INSECURE=false)"
    fi
    return 0
  fi

  if [[ -n "${PPDM_INSECURE:-}" ]]; then
    if resolve_curl_insecure; then
      export PPDM_CURL_INSECURE=true
      log_warn "Using PPDM_INSECURE=true from environment"
    else
      log_info "TLS verification enabled (PPDM_INSECURE=false)"
    fi
    return 0
  fi

  if [[ -n "${CURL_INSECURE:-}" ]]; then
    if resolve_curl_insecure; then
      export PPDM_CURL_INSECURE=true
      log_warn "Using CURL_INSECURE=true from environment"
    else
      log_info "TLS verification enabled (CURL_INSECURE=false)"
    fi
    return 0
  fi

  local answer
  read -rp "Skip TLS certificate verification for self-signed PPDM certificates? (y/N): " answer
  case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
    y|yes)
      export PPDM_CURL_INSECURE=true
      log_warn "TLS verification disabled (PPDM_CURL_INSECURE=true) — use only in lab/trusted networks"
      ;;
    *)
      log_info "TLS verification enabled"
      ;;
  esac
}

format_ppdm_connection_error() {
  local detail="$1"
  append_curl_ssl_error_hint "$detail"
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
      die "Failed to reach PPDM at ${PPDM_BASE_URL}: $(format_ppdm_connection_error "$api_error")"
    fi
    if [[ -n "$body" ]]; then
      die "Failed to reach PPDM at ${PPDM_BASE_URL}: $(format_ppdm_connection_error "$body")"
    fi
    die "Failed to reach PPDM at ${PPDM_BASE_URL} (connection error)$(curl_ssl_error_hint)"
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

ppdm_env_check_main() {
  log_info "Checking required commands..."
  need_cmd curl
  need_cmd jq
  log_info "Required commands available"

  wipe_ppdm_env_file

  # Step 0: Determine PPDM_BASE_URL
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

  configure_ppdm_tls

  authenticate

  write_ppdm_env_file

  log_info "Environment ready: credentials saved to ${PPDM_ENV_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ppdm_env_check_main "$@"
fi
