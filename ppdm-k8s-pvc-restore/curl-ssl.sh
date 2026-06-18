#!/usr/bin/env bash
# Shared curl TLS options for PPDM API calls.
#
# Prefer PPDM_CA_CERT when PPDM uses a private or self-signed CA.
# Use PPDM_CURL_INSECURE only for lab/testing (skips certificate verification).
#
# Environment:
#   PPDM_CA_CERT        Path to PEM CA bundle (recommended)
#   PPDM_CURL_INSECURE  true/1/yes — curl -k (skip TLS verification)
#   CURL_CA_CERT        Alias for PPDM_CA_CERT
#   CURL_INSECURE       Alias for PPDM_CURL_INSECURE
#   PPDM_INSECURE       Alias for PPDM_CURL_INSECURE

_curl_ssl_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes) return 0 ;;
    *) return 1 ;;
  esac
}

_curl_ssl_die() {
  if declare -F die >/dev/null 2>&1; then
    die "$@"
  fi
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

_curl_ssl_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$@"
  else
    printf '[INFO] %s\n' "$*" >&2
  fi
}

_curl_ssl_log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$@"
  elif declare -F log_info >/dev/null 2>&1; then
    log_info "$@"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

resolve_curl_ca_cert() {
  if [[ -n "${PPDM_CA_CERT:-}" ]]; then
    printf '%s\n' "$PPDM_CA_CERT"
    return 0
  fi
  if [[ -n "${CURL_CA_CERT:-}" ]]; then
    printf '%s\n' "$CURL_CA_CERT"
    return 0
  fi
  return 1
}

resolve_curl_insecure() {
  if [[ -n "${PPDM_CURL_INSECURE:-}" ]]; then
    _curl_ssl_truthy "$PPDM_CURL_INSECURE"
    return $?
  fi
  if [[ -n "${PPDM_INSECURE:-}" ]]; then
    _curl_ssl_truthy "$PPDM_INSECURE"
    return $?
  fi
  if [[ -n "${CURL_INSECURE:-}" ]]; then
    _curl_ssl_truthy "$CURL_INSECURE"
    return $?
  fi
  return 1
}

# Appends TLS-related curl flags to the named array (e.g. append_curl_ssl_args curl_args).
append_curl_ssl_args() {
  local array_name="$1"
  local ca_cert
  local -a ssl_args=()

  if ca_cert="$(resolve_curl_ca_cert)"; then
    [[ -r "$ca_cert" ]] || _curl_ssl_die "CA certificate file not found or not readable: ${ca_cert}"
    ssl_args+=(--cacert "$ca_cert")
    if [[ -z "${CURL_SSL_LOGGED:-}" ]]; then
      _curl_ssl_log_info "Using custom CA certificate for curl: ${ca_cert}"
      export CURL_SSL_LOGGED=1
    fi
  elif resolve_curl_insecure; then
    ssl_args+=(-k)
    if [[ -z "${CURL_SSL_LOGGED:-}" ]]; then
      _curl_ssl_log_warn "Curl TLS verification disabled (PPDM_CURL_INSECURE) — use only in lab/trusted networks"
      export CURL_SSL_LOGGED=1
    fi
  fi

  if ((${#ssl_args[@]} > 0)); then
    eval "${array_name}+=(\"\${ssl_args[@]}\")"
  fi
}
