#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PPDM Kubernetes PVC Restore — API execution
#
# Usage:
#   ppdm-restore-selected-pvcs-api.sh COPY_ID TARGET_NAMESPACE [PVC_SPECS] \
#       [TARGET_INV_ID] [NS_LABELS] [NS_ANNOTATIONS]
#
# PVC_SPECS: comma-separated PVC names, or "name:storageClass" pairs.
#             Leave empty to restore all PVCs in the copy.
#
# Requires: PPDM env file from ppdm-env-check.sh (or PPDM_* in environment)
# ------------------------------------------------------------

# API reference:
# https://developer.dell.com/apis/4378/versions/20.1.0/backup-and-restore-kubernetes-5987m0
PPDM_K8S_RESTORE_DOC="https://developer.dell.com/apis/4378/versions/20.1.0/backup-and-restore-kubernetes-5987m0"

MAPPING_FILE="${MAPPING_FILE:-pvc-restore-mapping-$(date +%Y%m%d-%H%M%S).tsv}"
SKIP_NAMESPACE_RESOURCES="${SKIP_NAMESPACE_RESOURCES:-true}"
RESTORE_TYPE="${RESTORE_TYPE:-}"
OVERWRITE_PVC="${OVERWRITE_PVC:-false}"
POLL_ACTIVITY="${POLL_ACTIVITY:-false}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-15}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-3600}"

usage() {
  cat >&2 <<'EOF'
Usage:
  ppdm-restore-selected-pvcs-api.sh COPY_ID TARGET_NAMESPACE [PVC_SPECS] \
      [TARGET_INV_ID] [NS_LABELS] [NS_ANNOTATIONS]

Arguments:
  COPY_ID           PPDM backup copy ID
  TARGET_NAMESPACE  Destination Kubernetes namespace
  PVC_SPECS         Optional comma-separated PVC names, or name:storageClass pairs
  TARGET_INV_ID     Optional target cluster inventory source ID
  NS_LABELS         Optional namespace labels (key=val,...)
  NS_ANNOTATIONS    Optional namespace annotations (key=val,...)

Environment:
  PPDM_BASE_URL, PPDM_TOKEN          Required (from .ppdm-env.cfg or environment)
  PPDM_ENV_FILE                      Path to env file (default: .ppdm-env.cfg)
  MAPPING_FILE                       Output mapping file path
  SKIP_NAMESPACE_RESOURCES           Default: true (PVC-only restore)
  OVERWRITE_PVC                      Default: false
  POLL_ACTIVITY                      Poll restore activity until completion
  POLL_INTERVAL_SEC / POLL_TIMEOUT_SEC
  PPDM_OPENSHIFT_SA                  OpenShift service account name (default: ppdm-serviceaccount)
  PPDM_OPENSHIFT_SCC                 OpenShift SCC to grant (default: anyuid)
  PPDM_LOG_DIR                       Log directory (default: logs/)
  PPDM_LOG_FILE                      Reuse an existing log file from a parent script

Restore type:
  This script always uses TO_EXISTING for Kubernetes PVC restore via
  POST /api/v2/restored-copies (see PPDM Kubernetes backup/restore guide).
  RESTORE_TYPE is ignored with a warning if set to another value.

  Reference: https://developer.dell.com/apis/4378/versions/20.1.0/backup-and-restore-kubernetes-5987m0
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=ppdm-logging.sh
source "${SCRIPT_DIR}/ppdm-logging.sh"
# shellcheck source=k8s-cli.sh
source "${SCRIPT_DIR}/k8s-cli.sh"
# shellcheck source=curl-ssl.sh
source "${SCRIPT_DIR}/curl-ssl.sh"
# shellcheck source=ppdm-env-cfg.sh
source "${SCRIPT_DIR}/ppdm-env-cfg.sh"

need_k8s_cli() {
  detect_k8s_cli || die "Missing required command: oc or kubectl"
  log_info "Using cluster CLI: ${K8S_CLI}"
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

ppdm_api_request() {
  local method="$1"
  local url="$2"
  local context="$3"
  local payload="${4:-}"

  local http_code body api_error response_file curl_error
  local -a curl_args

  log_info "${context}"

  response_file="$(mktemp)"
  curl_error="$(mktemp)"

  curl_args=(
    -sS
    -o "$response_file"
    -w '%{http_code}'
    -X "$method"
    -H "Authorization: Bearer $PPDM_TOKEN"
    -H "Content-Type: application/json"
    "$url"
  )

  if [[ -n "$payload" ]]; then
    curl_args+=(-d "$payload")
  fi
  append_curl_ssl_args curl_args

  if ! http_code="$(curl "${curl_args[@]}" 2>"$curl_error")"; then
    api_error="$(cat "$curl_error" 2>/dev/null || true)"
    rm -f "$response_file" "$curl_error"
    if [[ -n "$api_error" ]]; then
      die "${context} failed: ${api_error}"
    fi
    die "${context} failed (connection error)"
  fi

  body="$(cat "$response_file")"
  rm -f "$response_file" "$curl_error"

  if [[ ! "$http_code" =~ ^[0-9]{3}$ ]]; then
    die "${context} failed: unexpected response (missing HTTP status)"
  fi

  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
    echo "$body"
    return 0
  fi

  api_error="$(extract_api_error "$body")"
  if [[ -n "$api_error" ]]; then
    die "${context} failed (HTTP ${http_code}): ${api_error}"
  fi

  if [[ -z "$body" ]]; then
    die "${context} failed (HTTP ${http_code}): empty response body"
  fi

  die "${context} failed (HTTP ${http_code})"
}

parse_key_value_list() {
  local input="$1"
  local kind="$2"
  local -a pairs
  local pair key value

  [[ -n "$input" ]] || return 0

  IFS=',' read -r -a pairs <<< "$input"
  for pair in "${pairs[@]}"; do
    pair="${pair// /}"
    [[ -n "$pair" ]] || continue
    [[ "$pair" == *"="* ]] || die "Invalid ${kind} entry '${pair}' (expected key=value)"

    key="${pair%%=*}"
    value="${pair#*=}"
    [[ -n "$key" ]] || die "Invalid ${kind} entry '${pair}' (empty key)"

    printf '%s\t%s\n' "$key" "$value"
  done
}

build_pvc_array() {
  local pvc_specs="$1"

  if [[ -z "$pvc_specs" ]]; then
    echo "null"
    return 0
  fi

  local -a entries
  local entry name storage_class
  local json_array="[]"

  IFS=',' read -r -a entries <<< "$pvc_specs"
  for entry in "${entries[@]}"; do
    entry="${entry// /}"
    [[ -n "$entry" ]] || continue

    if [[ "$entry" == *":"* ]]; then
      name="${entry%%:*}"
      storage_class="${entry#*:}"
      [[ -n "$name" && -n "$storage_class" ]] || \
        die "Invalid PVC spec '${entry}' (expected name or name:storageClass)"
      json_array="$(echo "$json_array" | jq -c \
        --arg name "$name" \
        --arg sc "$storage_class" \
        '. + [{name: $name, alternateStorageClass: $sc}]')"
    else
      name="$entry"
      json_array="$(echo "$json_array" | jq -c \
        --arg name "$name" \
        '. + [{name: $name}]')"
    fi
  done

  [[ "$json_array" != "[]" ]] || die "PVC_SPECS was provided but no valid PVC names were parsed"
  echo "$json_array"
}

resolve_restore_type() {
  local forced="TO_EXISTING"

  if [[ -n "$RESTORE_TYPE" && "$RESTORE_TYPE" != "$forced" ]]; then
    log_warn "RESTORE_TYPE=${RESTORE_TYPE} ignored — PVC restore uses ${forced} per PPDM API"
    log_warn "See: ${PPDM_K8S_RESTORE_DOC}"
  fi

  echo "$forced"
}

is_openshift_cluster() {
  detect_k8s_cli || return 1
  [[ "$K8S_CLI" == "oc" ]]
}

configure_openshift_restore_namespace() {
  local target_namespace="$1"
  local sa_name="${PPDM_OPENSHIFT_SA:-ppdm-serviceaccount}"
  local scc_name="${PPDM_OPENSHIFT_SCC:-anyuid}"

  log_info "Configuring OpenShift prerequisites in '${target_namespace}' (required for PPDM cproxy)"

  if ! oc get serviceaccount "$sa_name" -n "$target_namespace" >/dev/null 2>&1; then
    log_info "Creating service account '${sa_name}' in '${target_namespace}'"
    oc create serviceaccount "$sa_name" -n "$target_namespace"
  else
    log_info "Service account '${sa_name}' already exists in '${target_namespace}'"
  fi

  log_info "Granting SCC '${scc_name}' to system:serviceaccount:${target_namespace}:${sa_name}"
  oc adm policy add-scc-to-user "$scc_name" \
    "system:serviceaccount:${target_namespace}:${sa_name}" \
    -n "$target_namespace"
}

ensure_restore_target_namespace() {
  local target_namespace="$1"

  log_info "Restore type forced to TO_EXISTING (${PPDM_K8S_RESTORE_DOC})"

  detect_k8s_cli || \
    die "oc or kubectl is required to prepare target namespace '${target_namespace}'"

  if ! "$K8S_CLI" get namespace "$target_namespace" >/dev/null 2>&1; then
    log_info "Target namespace '${target_namespace}' not found — creating it (${K8S_CLI})"
    "$K8S_CLI" create namespace "$target_namespace"
  else
    log_info "Target namespace '${target_namespace}' already exists (${K8S_CLI})"
  fi

  if is_openshift_cluster; then
    configure_openshift_restore_namespace "$target_namespace"
  fi
}

build_restore_payload() {
  local copy_id="$1"
  local target_namespace="$2"
  local pvc_specs="$3"
  local target_inv_id="$4"
  local restore_type="$5"

  local pvc_array target_k8s
  pvc_array="$(build_pvc_array "$pvc_specs")"

  log_info "Using restore type: ${restore_type}"

  target_k8s="$(jq -n \
    --arg namespace "$target_namespace" \
    --argjson skip_ns "$([[ "$SKIP_NAMESPACE_RESOURCES" == true ]] && echo true || echo false)" \
    --argjson overwrite "$([[ "$OVERWRITE_PVC" == true ]] && echo true || echo false)" \
    --arg inv_id "$target_inv_id" \
  '{
    namespace: $namespace,
    skipNamespaceResources: $skip_ns,
    overwritePersistentVolumeClaim: $overwrite
  }
  + (if ($inv_id | length) > 0 then {targetInventorySourceId: $inv_id} else {} end)')"

  if [[ "$pvc_array" != "null" ]]; then
    target_k8s="$(echo "$target_k8s" | jq --argjson pvcs "$pvc_array" '. + {persistentVolumeClaims: $pvcs}')"
  fi

  jq -n \
    --arg copy_id "$copy_id" \
    --arg description "Restore Kubernetes PVCs (${restore_type})" \
    --arg restore_type "$restore_type" \
    --argjson target_k8s "$target_k8s" \
    '{
      description: $description,
      restoreType: $restore_type,
      copyIds: [$copy_id],
      restoredCopiesDetails: {
        targetK8sInfo: $target_k8s
      }
    }'
}

write_mapping_file() {
  local target_namespace="$1"
  local pvc_specs="$2"
  local activity_id="$3"
  local mapping_path

  mapping_path="$(pwd)/${MAPPING_FILE}"
  log_info "Writing PVC mapping file: ${mapping_path}"

  {
    printf 'source_pvc\ttarget_pvc\ttarget_namespace\tactivity_id\n'
    if [[ -z "$pvc_specs" ]]; then
      printf '%s\t%s\t%s\t%s\n' '<all>' '<all>' "$target_namespace" "$activity_id"
    else
      local -a entries
      local entry name
      IFS=',' read -r -a entries <<< "$pvc_specs"
      for entry in "${entries[@]}"; do
        entry="${entry// /}"
        [[ -n "$entry" ]] || continue
        name="${entry%%:*}"
        printf '%s\t%s\t%s\t%s\n' "$name" "$name" "$target_namespace" "$activity_id"
      done
    fi
  } >"$mapping_path"
}

apply_namespace_metadata() {
  local target_namespace="$1"
  local labels_csv="$2"
  local annotations_csv="$3"
  local -a k8s_cmd

  if [[ -z "$labels_csv" && -z "$annotations_csv" ]]; then
    return 0
  fi

  if ! detect_k8s_cli; then
    log_info "oc/kubectl not available — skipping namespace labels/annotations"
    return 0
  fi

  if ! "$K8S_CLI" get namespace "$target_namespace" >/dev/null 2>&1; then
    log_warn "Target namespace '${target_namespace}' not found — skipping labels/annotations"
    return 0
  fi

  if [[ -n "$labels_csv" ]]; then
    k8s_cmd=("$K8S_CLI" label namespace "$target_namespace" --overwrite)
    while IFS=$'\t' read -r key value; do
      [[ -n "$key" ]] || continue
      k8s_cmd+=("${key}=${value}")
    done < <(parse_key_value_list "$labels_csv" "label")

    if [[ ${#k8s_cmd[@]} -gt 4 ]]; then
      log_info "Applying namespace labels to '${target_namespace}' (${K8S_CLI})"
      "${k8s_cmd[@]}"
    fi
  fi

  if [[ -n "$annotations_csv" ]]; then
    k8s_cmd=("$K8S_CLI" annotate namespace "$target_namespace" --overwrite)
    while IFS=$'\t' read -r key value; do
      [[ -n "$key" ]] || continue
      k8s_cmd+=("${key}=${value}")
    done < <(parse_key_value_list "$annotations_csv" "annotation")

    if [[ ${#k8s_cmd[@]} -gt 4 ]]; then
      log_info "Applying namespace annotations to '${target_namespace}' (${K8S_CLI})"
      "${k8s_cmd[@]}"
    fi
  fi
}

ppdm_api_get() {
  ppdm_api_request "GET" "$1" "${2:-PPDM API GET request}"
}

submit_restore() {
  local payload="$1"

  log_info "Submitting restore request to PPDM"
  echo "$payload" | jq '.' >&2

  ppdm_api_request "POST" "${PPDM_BASE_URL}/api/v2/restored-copies" \
    "Submitting Kubernetes PVC restore (POST /api/v2/restored-copies)" \
    "$payload"
}

poll_restore_activity() {
  local activity_id="$1"
  local elapsed=0
  local response state progress result_status

  log_info "Polling restore activity ${activity_id} (timeout ${POLL_TIMEOUT_SEC}s)"

  while (( elapsed < POLL_TIMEOUT_SEC )); do
    response="$(ppdm_api_get "${PPDM_BASE_URL}/api/v2/activities/${activity_id}" \
      "Checking restore activity status")"

    state="$(echo "$response" | jq -r '.state // empty')" || die "Failed to parse activity status"
    progress="$(echo "$response" | jq -r '.progress // "n/a"')"
    result_status="$(echo "$response" | jq -r '.result.status // empty')"

    log_info "Activity state=${state} progress=${progress} result=${result_status:-n/a}"

    case "$state" in
      COMPLETED|SUCCESS|SUCCEEDED)
        log_info "Restore activity completed successfully"
        return 0
        ;;
      FAILED|CANCELED|CANCELLED|ERROR)
        die "Restore activity ended with state: ${state}"
        ;;
    esac

    sleep "$POLL_INTERVAL_SEC"
    elapsed=$((elapsed + POLL_INTERVAL_SEC))
  done

  die "Timed out waiting for restore activity ${activity_id} after ${POLL_TIMEOUT_SEC}s"
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

init_ppdm_logging "ppdm-restore-selected-pvcs-api"

log_info "Checking required commands..."
need_cmd curl
need_cmd jq
log_info "Required commands available"

ensure_ppdm_env

COPY_ID="${1:-}"
TARGET_NAMESPACE="${2:-}"
PVC_SPECS="${3:-}"
TARGET_INV_ID="${4:-}"
NS_LABELS="${5:-}"
NS_ANNOTATIONS="${6:-}"
SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-}"

[[ -n "$COPY_ID" && -n "$TARGET_NAMESPACE" ]] || {
  usage
  die "Missing required arguments: COPY_ID and TARGET_NAMESPACE"
}

log_info "Using PPDM_BASE_URL=${PPDM_BASE_URL}"
log_info "Copy ID: ${COPY_ID}"
log_info "Source namespace: ${SOURCE_NAMESPACE:-<not set>}"
log_info "Target namespace: ${TARGET_NAMESPACE}"
log_info "PVC specs: ${PVC_SPECS:-<all>}"
log_info "PVC-only restore: ${SKIP_NAMESPACE_RESOURCES}"
[[ -n "$TARGET_INV_ID" ]] && log_info "Target inventory source ID: ${TARGET_INV_ID}"
[[ -n "$NS_LABELS" ]] && log_info "Namespace labels: ${NS_LABELS}"
[[ -n "$NS_ANNOTATIONS" ]] && log_info "Namespace annotations: ${NS_ANNOTATIONS}"

SELECTED_RESTORE_TYPE="$(resolve_restore_type)"
ensure_restore_target_namespace "$TARGET_NAMESPACE"

PAYLOAD="$(build_restore_payload "$COPY_ID" "$TARGET_NAMESPACE" "$PVC_SPECS" "$TARGET_INV_ID" "$SELECTED_RESTORE_TYPE")" || \
  die "Failed to build restore payload"

RESPONSE="$(submit_restore "$PAYLOAD")"

ACTIVITY_ID="$(echo "$RESPONSE" | jq -r '.activityId // .id // empty')" || \
  die "Failed to parse restore response (invalid JSON)"

[[ -n "$ACTIVITY_ID" && "$ACTIVITY_ID" != "null" ]] || \
  die "Restore request accepted but no activity ID was returned"

RESTORE_JOB_ID="$(echo "$RESPONSE" | jq -r '.id // empty')"
[[ -n "$RESTORE_JOB_ID" && "$RESTORE_JOB_ID" != "null" ]] && \
  log_info "Restore job ID: ${RESTORE_JOB_ID}"
log_info "Restore activity submitted: ${ACTIVITY_ID}"

write_mapping_file "$TARGET_NAMESPACE" "$PVC_SPECS" "$ACTIVITY_ID"
apply_namespace_metadata "$TARGET_NAMESPACE" "$NS_LABELS" "$NS_ANNOTATIONS"

if [[ "$POLL_ACTIVITY" == true ]]; then
  poll_restore_activity "$ACTIVITY_ID"
else
  log_info "Monitor activity: ${PPDM_BASE_URL}/api/v2/activities/${ACTIVITY_ID}"
  log_info "Set POLL_ACTIVITY=true to wait for completion in this script"
fi

log_info "Restore execution completed"
