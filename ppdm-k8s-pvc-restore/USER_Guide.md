# PPDM Kubernetes PVC Restore — User Guide

This guide walks you through restoring Kubernetes PersistentVolumeClaims (PVCs) from [Dell PowerProtect Data Manager (PPDM)](https://www.dell.com/en-us/dt/data-protection/powerprotect-data-manager.htm) backups using the scripts in this directory.

## What this toolkit does

The toolkit authenticates to PPDM, helps you pick a backup copy and PVCs, then submits a restore job to the PPDM REST API.

```
ppdm-env-check.sh  →  pvc_restore_wrapper.sh  →  ppdm-restore-selected-pvcs-api.sh
   (authenticate)        (interactive setup)            (restore execution)
```

| Script | Role |
|--------|------|
| `ppdm-env-check.sh` | Connect to PPDM and obtain an API token |
| `pvc_restore_wrapper.sh` | Interactive prompts for namespace, copy, and PVC selection |
| `ppdm-restore-selected-pvcs-api.sh` | Submit the restore request to PPDM |

---

## Before you begin

### Requirements

| Tool | Purpose |
|------|---------|
| `bash` | Run the scripts |
| `curl` | Call the PPDM REST API |
| `jq` | Parse API responses |
| `kubectl` or `oc` | List PVCs and verify namespaces (`oc` preferred when both are installed) |

### Access you need

- **PPDM** — hostname or IP, username, and password with permission to browse assets/copies and start restores
- **Kubernetes** — `kubectl` (or `oc`) configured for the cluster where the source namespace lives
- **Backup coverage** — the source namespace must exist as a `KUBERNETES` / `K8S_NAMESPACE` asset in PPDM

### Prepare your environment

```bash
cd ppdm-k8s-pvc-restore
chmod +x ppdm-env-check.sh pvc_restore_wrapper.sh ppdm-restore-selected-pvcs-api.sh
```

Verify cluster access:

```bash
kubectl get ns   # or: oc get ns
kubectl get pvc -n <your-source-namespace>
```

---

## Step-by-step restore

### Step 1 — Authenticate to PPDM

Run the auth script **in your current shell** so exported variables are available to the next script:

```bash
source ./ppdm-env-check.sh
```

You will be prompted for:

| Prompt | Example | Notes |
|--------|---------|-------|
| PPDM Host | `ppdm.example.com` | FQDN or IP; port `8443` is added automatically unless you include one |
| PPDM Username | `admin` | Cannot be empty |
| PPDM Password | *(hidden)* | Cannot be empty; not logged by the script |

#### What you should see

The script writes timestamped log lines to stderr:

```
[2026-06-17 19:34:14] [INFO] Checking required commands...
[2026-06-17 19:34:14] [INFO] Required commands available
[2026-06-17 19:34:14] [INFO] Using PPDM_BASE_URL=https://ppdm.example.com:8443
[2026-06-17 19:34:14] [INFO] Authenticating to PPDM at https://ppdm.example.com:8443...
[2026-06-17 19:34:15] [INFO] Authentication successful (HTTP 200)
[2026-06-17 19:34:15] [INFO] Environment ready: PPDM_BASE_URL and PPDM_TOKEN exported
```

Confirm the variables are set:

```bash
echo "$PPDM_BASE_URL"
# PPDM_TOKEN is set but should not be printed in shared logs
```

> **Important:** Do not run `bash ./ppdm-env-check.sh` in a subshell unless you capture exports manually — `source` keeps `PPDM_BASE_URL` and `PPDM_TOKEN` in your session.

---

### Step 2 — Run the interactive restore workflow

```bash
./pvc_restore_wrapper.sh
```

The wrapper guides you through the following prompts.

#### 2a. Namespaces

| Prompt | Description |
|--------|-------------|
| Source namespace | Namespace backed up in PPDM (where PVCs were protected) |
| Target namespace | Namespace where PVCs will be restored |

You can pre-set these to skip prompts:

```bash
export SOURCE_NAMESPACE=my-app
export TARGET_NAMESPACE=my-app-restored
```

#### 2b. Find the PPDM asset

The script searches PPDM for a Kubernetes namespace asset matching the source namespace name.

- On success: `Asset ID: <uuid>`
- On failure: `Namespace asset not found` — verify the namespace is protected in PPDM and the name matches exactly

#### 2c. Select a backup copy

A numbered list of copies is shown with ID, creation time, and location:

```
Available copies:
 1. abc123...   2026-06-10T12:00:00Z   primary
 2. def456...   2026-06-09T12:00:00Z   primary
Select copy number:
```

Enter the number of the copy you want to restore from.

#### 2d. Select PVCs

PVCs are listed from the **live** source namespace via `kubectl`:

```
Available PVCs:
 1) data-pvc
 2) config-pvc
Select PVC numbers (comma-separated or 'all'):
```

| Input | Result |
|-------|--------|
| `1` | Restore only the first PVC |
| `1,3` | Restore PVCs 1 and 3 |
| `all` | Restore every PVC in the namespace |

#### 2e. Optional restore options

| Prompt | Format | Purpose |
|--------|--------|---------|
| Target inventory source ID | UUID or blank | Target cluster inventory in PPDM (if required by your environment) |
| Namespace labels | `key=val,key2=val2` | Labels applied to the target namespace |
| Namespace annotations | `key=val,key2=val2` | Annotations applied to the target namespace |

#### 2f. Restore execution

The wrapper calls `ppdm-restore-selected-pvcs-api.sh` with the collected values:

```
COPY_ID, TARGET_NAMESPACE, PVC_SPECS, TARGET_INV_ID, NS_LABELS, NS_ANNOTATIONS
```

On completion: `Restore workflow completed`

#### Restore type (PPDM API)

This toolkit always submits **`TO_EXISTING`** restores via `POST /api/v2/restored-copies`, as documented in the [PPDM Kubernetes backup and restore guide](https://developer.dell.com/apis/4378/versions/20.1.0/backup-and-restore-kubernetes-5987m0).

| Behavior | Detail |
|----------|--------|
| Restore type | Always `TO_EXISTING` (other `RESTORE_TYPE` values are ignored with a warning) |
| Target namespace | Must already exist in the cluster |
| PVC-only (default) | `skipNamespaceResources: true` with selected `persistentVolumeClaims` |

If the target namespace is missing, the script logs a **warning** and continues — create the namespace first if the restore fails.

---

## Non-interactive usage

Set environment variables before running to reduce prompts:

```bash
export PPDM_HOST=ppdm.example.com
export PPDM_USER=admin
export PPDM_PASSWORD='your-password'
source ./ppdm-env-check.sh

export SOURCE_NAMESPACE=my-app
export TARGET_NAMESPACE=my-app-restored
./pvc_restore_wrapper.sh
```

If `PPDM_BASE_URL` is already set, it takes priority over `PPDM_HOST`. URLs are normalized automatically:

| Input | Normalized to |
|-------|---------------|
| `ppdm.example.com` | `https://ppdm.example.com:8443` |
| `https://ppdm.example.com:8443` | `https://ppdm.example.com:8443` |
| `ppdm.example.com:9443` | `https://ppdm.example.com:9443` |

---

## Environment variables

| Variable | Set by | Description |
|----------|--------|-------------|
| `PPDM_BASE_URL` | `ppdm-env-check.sh` | PPDM API base URL |
| `PPDM_TOKEN` | `ppdm-env-check.sh` | Bearer token from PPDM login |
| `PPDM_HOST` | user | PPDM hostname or IP (used when `PPDM_BASE_URL` is unset) |
| `PPDM_USER` | user | PPDM username |
| `PPDM_PASSWORD` | user | PPDM password |
| `SOURCE_NAMESPACE` | user | Source Kubernetes namespace |
| `TARGET_NAMESPACE` | user | Target Kubernetes namespace (must exist for `TO_EXISTING`) |
| `SKIP_NAMESPACE_RESOURCES` | user | `true` (default) = PVC-only; `false` = include namespace resources |
| `RESTORE_SCRIPT` | user | Path to restore script (default: `./ppdm-restore-selected-pvcs-api.sh`) |

---

## Troubleshooting

### Authentication (`ppdm-env-check.sh`)

| Error | Likely cause | What to try |
|-------|--------------|-------------|
| `Missing required command: curl` or `jq` | Dependency not installed | Install the missing tool |
| `PPDM host/URL cannot be empty` | Blank host entered | Provide a valid FQDN or IP |
| `PPDM username cannot be empty` | Blank username | Re-run and enter credentials |
| `Failed to reach PPDM at ...: curl: (6) Could not resolve host` | DNS or network issue | Verify hostname, DNS, and firewall routes to PPDM |
| `Failed to reach PPDM at ... (connection error)` | PPDM unreachable or TLS issue | Check PPDM is running, port `8443` is open, and certificates are valid |
| `Authentication failed (HTTP 401): ...` | Invalid credentials | Verify username and password in PPDM |
| `Authentication failed (HTTP 4xx/5xx): ...` | API or permission issue | Read the message after the HTTP code; check PPDM logs |
| `no access_token was returned` | Unexpected API response | Confirm PPDM version supports `POST /api/v2/login` |

All auth errors are logged as `[ERROR]` lines with a clear message. Logs go to **stderr**; normal exports go to your shell environment.

### Restore workflow (`pvc_restore_wrapper.sh`)

| Error | Likely cause | What to try |
|-------|--------------|-------------|
| `PPDM_BASE_URL is not set` | Auth step skipped or run in subshell | Run `source ./ppdm-env-check.sh` in the same shell first |
| `PPDM_TOKEN is not set` | Auth failed or session cleared | Re-authenticate |
| `Namespace asset not found` | Namespace not protected in PPDM | Confirm the namespace is registered as a K8s namespace asset |
| `No PVCs found` | Empty namespace or wrong context | Run `kubectl get pvc -n <namespace>`; check `kubectl config current-context` |
| `Invalid selection` | Bad copy number | Pick a number from the displayed list |
| `Target namespace not found` (WARN) | Namespace does not exist yet | `kubectl create namespace <name>` before restore |
| `RESTORE_TYPE=... ignored` (WARN) | Unsupported restore type requested | Script forces `TO_EXISTING` per PPDM API |
| `Missing required command: oc or kubectl` | No cluster CLI in PATH | Install `oc` (OpenShift) or `kubectl` and configure cluster access |

---

## Security notes

- Run `ppdm-env-check.sh` separately so credentials stay out of the restore scripts.
- Prefer `read -rsp` prompts over exporting `PPDM_PASSWORD` in shell history when working interactively.
- Do not log or share `PPDM_TOKEN` — treat it like a password.
- Clear sensitive variables when finished:

```bash
unset PPDM_PASSWORD PPDM_TOKEN
```

---

## Quick reference

```bash
# Full interactive flow
cd ppdm-k8s-pvc-restore
source ./ppdm-env-check.sh
./pvc_restore_wrapper.sh
```

For script-level technical details, see the repository [README.md](../README.md).
