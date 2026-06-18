#!/usr/bin/env bash
# Shared logging to stderr and logs/ directory.
#
# Environment:
#   PPDM_LOG_DIR   Log directory (default: <toolkit>/logs)
#   PPDM_LOG_FILE  Reuse an existing log file (set by parent script or user)

PPDM_LOGGING_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PPDM_LOG_DIR="${PPDM_LOG_DIR:-${PPDM_LOGGING_HOME}/logs}"

_ppdm_log_write() {
  local line="$1"
  printf '%s' "$line" >&2
  if [[ -n "${PPDM_LOG_FILE:-}" ]]; then
    printf '%s' "$line" >>"$PPDM_LOG_FILE"
  fi
}

log() {
  local level="$1"
  shift
  _ppdm_log_write "$(printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*")"
}

log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
  log_error "$@"
  exit 1
}

init_ppdm_logging() {
  local script_name="${1:-ppdm}"
  script_name="${script_name%.sh}"

  mkdir -p "$PPDM_LOG_DIR" || {
    printf '[ERROR] Failed to create log directory: %s\n' "$PPDM_LOG_DIR" >&2
    exit 1
  }

  if [[ -n "${PPDM_LOG_FILE:-}" && -f "${PPDM_LOG_FILE}" ]]; then
    _ppdm_log_write "$(printf '[%s] [INFO] Continuing log file: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PPDM_LOG_FILE")"
    export PPDM_LOG_DIR PPDM_LOG_FILE
    return 0
  fi

  PPDM_LOG_FILE="${PPDM_LOG_DIR}/${script_name}-$(date +%Y%m%d-%H%M%S).log"
  export PPDM_LOG_DIR PPDM_LOG_FILE
  _ppdm_log_write "$(printf '[%s] [INFO] Log file: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$PPDM_LOG_FILE")"
}
