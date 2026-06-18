#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# PPDM Kubernetes PVC Restore Wrapper
# Requires: PPDM env file from ppdm-env-check.sh (or PPDM_* in environment)
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

ppdm_api_get() {
  local url="$1"
  local context="${2:-PPDM API request}"
  local http_code body api_error response_file curl_error
  local -a curl_args

  log_info "${context}"

  response_file="$(mktemp)"
  curl_error="$(mktemp)"

  curl_args=(
    -sS
    -o "$response_file"
    -w '%{http_code}'
    -H "Authorization: Bearer $PPDM_TOKEN"
    "$url"
  )
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

find_namespace_asset() {
  local namespace="$1"
  local assets asset_id

  assets="$(ppdm_api_get \
    "${PPDM_BASE_URL}/api/v2/assets?filter=type%20eq%20%22KUBERNETES%22%20and%20subtype%20eq%20%22K8S_NAMESPACE%22" \
    "Finding Kubernetes namespace asset for '${namespace}'")"

  asset_id="$(echo "$assets" | jq -r --arg ns "$namespace" '
    .content[]? | select(.name == $ns) | .id
  ' | head -n1)" || die "Failed to parse assets response (invalid JSON)"

  [[ -n "$asset_id" && "$asset_id" != "null" ]] || \
    die "Namespace asset not found for '${namespace}' (verify it is protected in PPDM)"

  log_info "Found asset ID: ${asset_id}"
  echo "$asset_id"
}

filter_copies_json_for_asset() {
  local copies="$1"
  local asset_id="$2"
  local namespace="$3"

  echo "$copies" | jq -c --arg aid "$asset_id" --arg ns "$namespace" '
    {content: [.content[]? | select(
      ((.assetId // .asset.id // "") == $aid) or
      ((.assetName // .asset.name // .protectedAssetName // "") == $ns)
    )]}
  '
}

select_backup_copy() {
  local asset_id="$1"
  local namespace="$2"
  local copies filtered_copies copy_count copy_num copy_id filter encoded_filter

  [[ -n "$asset_id" ]] || die "Asset ID is required to list backup copies"
  [[ -n "$namespace" ]] || die "Namespace is required to list backup copies"

  filter="assetId eq \"${asset_id}\""
  encoded_filter="$(printf '%s' "$filter" | jq -sRr @uri)"

  copies="$(ppdm_api_get \
    "${PPDM_BASE_URL}/api/v2/copies?filter=${encoded_filter}" \
    "Fetching backup copies for namespace '${namespace}'")"

  filtered_copies="$(filter_copies_json_for_asset "$copies" "$asset_id" "$namespace")"

  copy_count="$(echo "$filtered_copies" | jq -r '.content | length')" || \
    die "Failed to parse copies response (invalid JSON)"

  [[ "$copy_count" =~ ^[0-9]+$ && "$copy_count" -gt 0 ]] || \
    die "No backup copies available for namespace '${namespace}' (asset ${asset_id})"

  log_info "Found ${copy_count} backup copy/copies for namespace '${namespace}'"

  echo "Available copies:" >&2
  printf '%-4s %-38s %-22s %-24s %s\n' '#' 'Copy ID' 'Create Time' 'AssetName' 'Location' >&2
  echo "$filtered_copies" | jq -r '
    .content[]? |
    [
      .id,
      (.createTime // .createdAt // "n/a"),
      (.assetName // .asset.name // .protectedAssetName // "n/a"),
      (.location // "n/a")
    ] | @tsv' | awk -F'\t' '{ printf "%-4s %-38s %-22s %-24s %s\n", NR".", $1, $2, $3, $4 }' >&2

  read -rp "Select copy number: " copy_num

  [[ "$copy_num" =~ ^[0-9]+$ ]] || die "Invalid copy selection: '${copy_num}' is not a number"
  [[ "$copy_num" -ge 1 && "$copy_num" -le "$copy_count" ]] || \
    die "Invalid copy selection: choose a number between 1 and ${copy_count}"

  copy_id="$(echo "$filtered_copies" | jq -r ".content[$((copy_num - 1))].id")" || \
    die "Failed to read selected copy (invalid JSON)"

  [[ -n "$copy_id" && "$copy_id" != "null" ]] || die "Invalid copy selection: no copy ID returned"

  log_info "Selected copy ID: ${copy_id}"
  echo "$copy_id"
}

list_namespace_pvcs() {
  local namespace="$1"

  log_info "Listing PVCs in namespace '${namespace}'"

  if ! "$K8S_CLI" get namespace "$namespace" >/dev/null 2>&1; then
    die "Namespace '${namespace}' not found or not accessible with current ${K8S_CLI} context"
  fi

  mapfile -t PVC_NAMES < <(
    "$K8S_CLI" get pvc -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
      || die "Failed to list PVCs in namespace '${namespace}'"
  )

  [[ ${#PVC_NAMES[@]} -gt 0 ]] || \
    die "No PVCs found in namespace '${namespace}'"

  log_info "Found ${#PVC_NAMES[@]} PVC(s) in namespace '${namespace}'"

  echo "Available PVCs:" >&2
  for i in "${!PVC_NAMES[@]}"; do
    printf "%2d) %s\n" "$((i + 1))" "${PVC_NAMES[$i]}" >&2
  done
}

select_pvcs() {
  local selection
  local -a choices
  local choice idx specs=""

  read -rp "Select PVC numbers (comma-separated or 'all'): " selection
  selection="${selection// /}"

  if [[ -z "$selection" ]]; then
    die "PVC selection cannot be empty"
  fi

  if [[ "$selection" == "all" ]]; then
    log_info "All PVCs will be restored"
    echo ""
    return 0
  fi

  IFS=',' read -r -a choices <<< "$selection"
  for choice in "${choices[@]}"; do
    [[ "$choice" =~ ^[0-9]+$ ]] || die "Invalid PVC selection: '${choice}' is not a number"
    idx=$((choice - 1))
    [[ "$idx" -ge 0 && "$idx" -lt ${#PVC_NAMES[@]} ]] || \
      die "Invalid PVC selection: number ${choice} is out of range (1-${#PVC_NAMES[@]})"
    specs+="${PVC_NAMES[$idx]},"
  done

  specs="${specs%,}"
  log_info "Selected PVCs: ${specs}"
  echo "$specs"
}

run_restore() {
  local copy_id="$1"
  local target_namespace="$2"
  local pvc_specs="$3"
  local target_inv_id="$4"
  local ns_labels="$5"
  local ns_annotations="$6"

  [[ -f "$RESTORE_SCRIPT" ]] || die "Restore script not found: ${RESTORE_SCRIPT}"
  [[ -x "$RESTORE_SCRIPT" ]] || die "Restore script is not executable: ${RESTORE_SCRIPT}"

  log_info "Launching restore via ${RESTORE_SCRIPT}"
  log_info "Source namespace: ${SOURCE_NAMESPACE}"
  log_info "Target namespace: ${target_namespace}"
  log_info "PVC specs: ${pvc_specs:-<all>}"

  SOURCE_NAMESPACE="$SOURCE_NAMESPACE" \
  PPDM_BASE_URL="$PPDM_BASE_URL" \
  PPDM_TOKEN="$PPDM_TOKEN" \
  PPDM_ENV_FILE="$PPDM_ENV_FILE" \
    "$RESTORE_SCRIPT" \
    "$copy_id" \
    "$target_namespace" \
    "$pvc_specs" \
    "$target_inv_id" \
    "$ns_labels" \
    "$ns_annotations"
}

# ------------------------------------------------------------
# Requirements and environment
# ------------------------------------------------------------
log_info "Checking required commands..."
need_cmd curl
need_cmd jq
need_k8s_cli
log_info "Required commands available"

ensure_ppdm_env

SOURCE_NAMESPACE="${SOURCE_NAMESPACE:-}"
TARGET_NAMESPACE="${TARGET_NAMESPACE:-}"
RESTORE_SCRIPT="${RESTORE_SCRIPT:-./ppdm-restore-selected-pvcs-api.sh}"

log_info "Using PPDM_BASE_URL=${PPDM_BASE_URL}"
log_info "Using RESTORE_SCRIPT=${RESTORE_SCRIPT}"

# ------------------------------------------------------------
# Step 1: Namespaces
# ------------------------------------------------------------
if [[ -z "$SOURCE_NAMESPACE" ]]; then
  read -rp "Source namespace: " SOURCE_NAMESPACE
else
  log_info "Using SOURCE_NAMESPACE from environment"
fi

if [[ -z "$TARGET_NAMESPACE" ]]; then
  read -rp "Target namespace: " TARGET_NAMESPACE
else
  log_info "Using TARGET_NAMESPACE from environment"
fi

[[ -n "$SOURCE_NAMESPACE" ]] || die "Source namespace cannot be empty"
[[ -n "$TARGET_NAMESPACE" ]] || die "Target namespace cannot be empty"

log_info "Source namespace: ${SOURCE_NAMESPACE}"
log_info "Target namespace: ${TARGET_NAMESPACE}"

# ------------------------------------------------------------
# Step 2: Find namespace asset
# ------------------------------------------------------------
ASSET_ID="$(find_namespace_asset "$SOURCE_NAMESPACE")"

# ------------------------------------------------------------
# Step 3: Select copy
# ------------------------------------------------------------
COPY_ID="$(select_backup_copy "$ASSET_ID" "$SOURCE_NAMESPACE")"

# ------------------------------------------------------------
# Step 4: List PVCs
# ------------------------------------------------------------
list_namespace_pvcs "$SOURCE_NAMESPACE"

# ------------------------------------------------------------
# Step 5: Select PVCs
# ------------------------------------------------------------
PVC_SPECS="$(select_pvcs)"

# ------------------------------------------------------------
# Step 6: Optional restore options and execute
# ------------------------------------------------------------
read -rp "Target inventory source ID (optional): " TARGET_INV_ID
read -rp "Namespace labels (key=val,... optional): " NS_LABELS
read -rp "Namespace annotations (key=val,... optional): " NS_ANNOTATIONS

run_restore \
  "$COPY_ID" \
  "$TARGET_NAMESPACE" \
  "$PVC_SPECS" \
  "$TARGET_INV_ID" \
  "$NS_LABELS" \
  "$NS_ANNOTATIONS"

log_info "Restore workflow completed"
