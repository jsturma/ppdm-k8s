#!/usr/bin/env bash
# Shared Kubernetes/OpenShift CLI detection.
# Prefers oc when available; falls back to kubectl. Set K8S_CLI to override.

K8S_CLI="${K8S_CLI:-}"

detect_k8s_cli() {
  if [[ -n "${K8S_CLI:-}" ]]; then
    command -v "$K8S_CLI" >/dev/null 2>&1
    return $?
  fi

  if command -v oc >/dev/null 2>&1; then
    K8S_CLI=oc
    return 0
  fi

  if command -v kubectl >/dev/null 2>&1; then
    K8S_CLI=kubectl
    return 0
  fi

  return 1
}
