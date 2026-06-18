#!/usr/bin/env bash
# Shared logging to stderr and logs/ directory.
#
# Environment:
#   PPDM_LOG_DIR   Log directory (default: <toolkit>/logs)
#   PPDM_LOG_FILE  Reuse an existing log file (set by parent script or user)
#   PPDM_LOG_EOL   Line ending (default: CRLF)

PPDM_LOGGING_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPDM_LOG_DIR="${PPDM_LOG_DIR:-${PPDM_LOGGING_HOME}/logs}"
if [[ -z "${PPDM_LOG_EOL:-}" ]]; then
  PPDM_LOG_EOL=$'\r'$'\n'
fi

_ppdm_strip_trailing_eol() {
  local text="$1"
  while [[ "$text" == *$'\r' || "$text" == *$'\n' ]]; do
    text="${text%$'\r'}"
    text="${text%$'\n'}"
  done
  printf '%s' "$text"
}

_ppdm_emit() {
  local line="$1"
  local text
  text="$(_ppdm_strip_trailing_eol "$line")"
  printf '%s' "$text" >&2
  printf '%s' "$PPDM_LOG_EOL" >&2
  if [[ -n "${PPDM_LOG_FILE:-}" ]]; then
    printf '%s' "$text" >>"$PPDM_LOG_FILE"
    printf '%s' "$PPDM_LOG_EOL" >>"$PPDM_LOG_FILE"
  fi
}

log() {
  local level="$1"
  shift
  _ppdm_emit "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
  log_error "$@"
  exit 1
}

# User-facing console output (stderr + log file), CRLF-terminated.
ppdm_out() {
  _ppdm_emit "$*"
}

# Multi-line console output; each line CRLF-terminated.
ppdm_out_stream() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    _ppdm_emit "$line"
  done
}

_ppdm_read_line() {
  local __var="$1"
  local secret="${2:-false}"
  local value=""

  if [[ "$secret" == true ]]; then
    if [[ -r /dev/tty ]]; then
      IFS= read -rs value </dev/tty
    else
      IFS= read -rs value
    fi
  else
    if [[ -r /dev/tty ]]; then
      IFS= read -r value </dev/tty
    else
      IFS= read -r value
    fi
  fi

  printf -v "$__var" '%s' "$value"
}

# Interactive prompt: console prompt + input, then CRLF; input logged to file.
ppdm_prompt() {
  local __var="$1"
  local prompt="$2"
  local value=""

  printf '%s' "$prompt" >&2
  _ppdm_read_line value false
  printf '%s' "$PPDM_LOG_EOL" >&2
  _ppdm_emit "[$(date '+%Y-%m-%d %H:%M:%S')] [INPUT] ${prompt}${value}"
  printf -v "$__var" '%s' "$value"
}

# Hidden interactive prompt (passwords).
ppdm_prompt_secret() {
  local __var="$1"
  local prompt="$2"
  local value=""

  printf '%s' "$prompt" >&2
  _ppdm_read_line value true
  printf '%s' "$PPDM_LOG_EOL" >&2
  _ppdm_emit "[$(date '+%Y-%m-%d %H:%M:%S')] [INPUT] ${prompt}<redacted>"
  printf -v "$__var" '%s' "$value"
}

init_ppdm_logging() {
  local script_name="${1:-ppdm}"
  script_name="${script_name%.sh}"

  mkdir -p "$PPDM_LOG_DIR" || {
    printf '%s' "$(_ppdm_strip_trailing_eol "[ERROR] Failed to create log directory: ${PPDM_LOG_DIR}")" >&2
    printf '%s' "$PPDM_LOG_EOL" >&2
    exit 1
  }

  if [[ -n "${PPDM_LOG_FILE:-}" && -f "${PPDM_LOG_FILE}" ]]; then
    _ppdm_emit "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Continuing log file: ${PPDM_LOG_FILE}"
    export PPDM_LOG_DIR PPDM_LOG_FILE PPDM_LOG_EOL
    return 0
  fi

  PPDM_LOG_FILE="${PPDM_LOG_DIR}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
  export PPDM_LOG_DIR PPDM_LOG_FILE PPDM_LOG_EOL
  _ppdm_emit "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log file: ${PPDM_LOG_FILE}"
}
