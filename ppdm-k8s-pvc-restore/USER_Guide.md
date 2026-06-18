# PPDM Kubernetes PVC Restore — User Guide

This guide walks you through restoring Kubernetes PersistentVolumeClaims (PVCs) from [Dell PowerProtect Data Manager (PPDM)](https://www.dell.com/en-us/dt/data-protection/powerprotect-data-manager.htm) backups using the scripts in this directory.

## What this toolkit does

The toolkit authenticates to PPDM, helps you pick a backup copy and PVCs, then submits a restore job to the PPDM REST API.

```
ppdm-env-check.sh  →  .ppdm-env.cfg  →  pvc_restore_wrapper.sh  →  ppdm-restore-selected-pvcs-api.sh
   (authenticate)      (credentials)        (interactive setup)            (restore execution)
                              ↑                                    ↑
                         k8s-cli.sh (sourced)              k8s-cli.sh (sourced)
                         curl-ssl.sh (sourced)             curl-ssl.sh (sourced)
                         ppdm-env-cfg.sh (sourced)       ppdm-env-cfg.sh (sourced)
```

| Script / library | Role |
|------------------|------|
| `ppdm-env-check.sh` | Connect to PPDM, obtain an API token, write `.ppdm-env.cfg` |
| `ppdm-env-cfg.sh` | Read/write the PPDM env file; used by all API scripts |
| `curl-ssl.sh` | TLS options for curl (`PPDM_CA_CERT`, `PPDM_CURL_INSECURE`); sourced by all API scripts |
| `k8s-cli.sh` | Detect cluster CLI (`oc` or `kubectl`); sourced by wrapper and restore scripts |
| `pvc_restore_wrapper.sh` | Interactive prompts for namespace, copy, and PVC selection |
| `ppdm-restore-selected-pvcs-api.sh` | Submit the restore request to PPDM (`POST /api/v2/restored-copies`) |

---

## Before you begin

### Requirements

| Tool | Purpose |
|------|---------|
| `bash` | Run the scripts |
| `curl` | Call the PPDM REST API |
| `jq` | Parse API responses |
| `kubectl` or `oc` | List PVCs and verify namespaces (auto-selected — see `k8s-cli.sh`) |

### Cluster CLI (`k8s-cli.sh`)

Scripts that talk to the cluster (`pvc_restore_wrapper.sh`, `ppdm-restore-selected-pvcs-api.sh`) source **`k8s-cli.sh`** to pick the CLI at runtime:

| Priority | CLI | When used |
|----------|-----|-----------|
| 1 | `oc` | OpenShift CLI found on `PATH` |
| 2 | `kubectl` | Fallback when `oc` is not installed |
| Override | `$K8S_CLI` | Force a specific binary (e.g. `export K8S_CLI=/path/to/oc`) |

On startup you should see:

```
[INFO] Using cluster CLI: oc
```

All namespace checks, PVC listing, and label/annotation commands use the selected CLI — not hard-coded `kubectl`.

### TLS / self-signed certificates (`curl-ssl.sh`)

PPDM often uses HTTPS with a private or self-signed CA. Scripts that call the PPDM API source **`curl-ssl.sh`** and pass TLS flags to every `curl` request.

| Option | Variable | When to use |
|--------|----------|-------------|
| Custom CA (recommended) | `PPDM_CA_CERT` | Path to the PEM file that signed the PPDM server certificate |
| Skip verification (lab only) | `PPDM_CURL_INSECURE=true` | Self-signed cert and you cannot provide a CA bundle — **not for production** |

Aliases: `CURL_CA_CERT`, `CURL_INSECURE`, and `PPDM_INSECURE` (same meaning as `PPDM_CURL_INSECURE`).

If both `PPDM_CA_CERT` and `PPDM_CURL_INSECURE` are set, the CA file takes precedence.

During `./ppdm-env-check.sh`, if neither `PPDM_CA_CERT` nor `PPDM_CURL_INSECURE` is set, you are prompted:

```
Skip TLS certificate verification for self-signed PPDM certificates? (y/N):
```

Answer `y` to set `PPDM_CURL_INSECURE=true` for this run (saved to `.ppdm-env.cfg` when enabled).

```bash
# Non-interactive: trust your PPDM CA
export PPDM_CA_CERT=/path/to/ppdm-ca.pem
./ppdm-env-check.sh

# Non-interactive: skip verification (lab only)
export PPDM_CURL_INSECURE=true
./ppdm-env-check.sh
```

On the first API call you should see either:

```
[INFO] Using custom CA certificate for curl: /path/to/ppdm-ca.pem
```

or (insecure mode):

```
[WARN] Curl TLS verification disabled (PPDM_CURL_INSECURE) — use only in lab/trusted networks
```

### Access you need

- **PPDM** — hostname or IP, username, and password with permission to browse assets/copies and start restores
- **Kubernetes / OpenShift** — `oc` or `kubectl` configured for the cluster where the source namespace lives
- **Backup coverage** — the source namespace must exist as a `KUBERNETES` / `K8S_NAMESPACE` asset in PPDM

### Prepare your environment

```bash
cd ppdm-k8s-pvc-restore
chmod +x ppdm-env-check.sh ppdm-env-cfg.sh curl-ssl.sh k8s-cli.sh pvc_restore_wrapper.sh ppdm-restore-selected-pvcs-api.sh
```

Verify cluster access (the toolkit will prefer `oc` when both are installed):

```bash
oc get ns 2>/dev/null || kubectl get ns
oc get pvc -n <your-source-namespace> 2>/dev/null || kubectl get pvc -n <your-source-namespace>
```

---

## Step-by-step restore

### Step 1 — Authenticate to PPDM

Run the auth script as a normal executable. It writes credentials to **`.ppdm-env.cfg`** (mode `600`) in this directory. If that file already exists, it is removed and recreated with fresh values.

```bash
./ppdm-env-check.sh
```

You will be prompted for:

| Prompt | Example | Notes |
|--------|---------|-------|
| PPDM Host | `ppdm.example.com` | FQDN or IP; port `8443` is added automatically unless you include one |
| PPDM Username | `admin` | Cannot be empty |
| PPDM Password | *(hidden)* | Cannot be empty; not stored in the env file |
| Skip TLS verification? | `y` or `N` | Only if `PPDM_CA_CERT` and `PPDM_CURL_INSECURE` are unset; `y` sets `PPDM_CURL_INSECURE=true` |

#### What you should see

The script writes timestamped log lines to stderr:

```
[2026-06-17 19:34:14] [INFO] Checking required commands...
[2026-06-17 19:34:14] [INFO] Required commands available
[2026-06-17 19:34:14] [INFO] Using PPDM_BASE_URL=https://ppdm.example.com:8443
[2026-06-17 19:34:14] [INFO] Authenticating to PPDM at https://ppdm.example.com:8443...
[2026-06-17 19:34:15] [INFO] Authentication successful (HTTP 200)
[2026-06-17 19:34:15] [INFO] Wrote PPDM env file: .../ppdm-k8s-pvc-restore/.ppdm-env.cfg
[2026-06-17 19:34:15] [INFO] Environment ready: credentials saved to .../ppdm-k8s-pvc-restore/.ppdm-env.cfg
```

The env file contains `PPDM_BASE_URL`, `PPDM_TOKEN`, and TLS settings (`PPDM_CA_CERT` / `PPDM_CURL_INSECURE`) when set. Passwords are **not** saved.

> **No `source` required.** Other scripts load `.ppdm-env.cfg` automatically. Override the path with `export PPDM_ENV_FILE=/path/to/custom.cfg`.

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

PVCs are listed from the **live** source namespace via the cluster CLI (`oc` or `kubectl`):

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
./ppdm-env-check.sh

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
| `PPDM_ENV_FILE` | user / default | Path to credentials file (default: `.ppdm-env.cfg` in this directory) |
| `PPDM_BASE_URL` | `.ppdm-env.cfg` | PPDM API base URL |
| `PPDM_TOKEN` | `.ppdm-env.cfg` | Bearer token from PPDM login |
| `PPDM_HOST` | user | PPDM hostname or IP (used when `PPDM_BASE_URL` is unset) |
| `PPDM_USER` | user | PPDM username |
| `PPDM_PASSWORD` | user | PPDM password |
| `PPDM_CA_CERT` | user | PEM CA bundle for PPDM HTTPS (self-signed / private CA) |
| `PPDM_CURL_INSECURE` | user | `true` = skip TLS verification for curl (lab only) |
| `K8S_CLI` | `k8s-cli.sh` / user | Cluster CLI to use (`oc` or `kubectl`; auto-detected if unset) |
| `SOURCE_NAMESPACE` | user | Source Kubernetes namespace |
| `TARGET_NAMESPACE` | user | Target Kubernetes namespace (must exist for `TO_EXISTING`) |
| `SKIP_NAMESPACE_RESOURCES` | user | `true` (default) = PVC-only; `false` = include namespace resources |
| `RESTORE_SCRIPT` | user | Path to restore script (default: `./ppdm-restore-selected-pvcs-api.sh`) |
| `MAPPING_FILE` | user | Output path for PVC mapping TSV (restore script) |
| `OVERWRITE_PVC` | user | `true` = overwrite existing PVC contents (restore script) |
| `POLL_ACTIVITY` | user | `true` = wait for restore activity to complete (restore script) |

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
| `curl: (60) SSL certificate problem` / `unable to get local issuer certificate` | Self-signed or private CA | Re-run `./ppdm-env-check.sh` and answer `y` at the TLS prompt, or set `export PPDM_CA_CERT=/path/to/ca.pem` or `export PPDM_CURL_INSECURE=true` before running |
| `CA certificate file not found or not readable` | Bad `PPDM_CA_CERT` path | Fix the path and file permissions |
| `Authentication failed (HTTP 401): ...` | Invalid credentials | Verify username and password in PPDM |
| `Authentication failed (HTTP 4xx/5xx): ...` | API or permission issue | Read the message after the HTTP code; check PPDM logs |
| `no access_token was returned` | Unexpected API response | Confirm PPDM version supports `POST /api/v2/login` |

All auth errors are logged as `[ERROR]` lines with a clear message. Logs go to **stderr**; normal exports go to your shell environment.

### Restore workflow (`pvc_restore_wrapper.sh`)

| Error | Likely cause | What to try |
|-------|--------------|-------------|
| `PPDM env file not found` | Auth step not run | Run `./ppdm-env-check.sh` first |
| `PPDM env file is missing PPDM_TOKEN` | Corrupt or hand-edited cfg | Re-run `./ppdm-env-check.sh` to recreate the file |
| `Namespace asset not found` | Namespace not protected in PPDM | Confirm the namespace is registered as a K8s namespace asset |
| `No PVCs found` | Empty namespace or wrong context | Run `oc get pvc -n <namespace>` or `kubectl get pvc -n <namespace>`; check current context |
| `Invalid selection` | Bad copy number | Pick a number from the displayed list |
| `Target namespace not found` (WARN) | Namespace does not exist yet | `oc create namespace <name>` or `kubectl create namespace <name>` before restore |
| `RESTORE_TYPE=... ignored` (WARN) | Unsupported restore type requested | Script forces `TO_EXISTING` per PPDM API |
| `Missing required command: oc or kubectl` | No cluster CLI in PATH | Install `oc` (OpenShift) or `kubectl`; or set `K8S_CLI` to the full path |
| `not accessible with current oc context` | Wrong OpenShift project/context | `oc config current-context` / `oc project <namespace>` |
| `not accessible with current kubectl context` | Wrong kubeconfig context | `kubectl config current-context` |

### Restore API (`ppdm-restore-selected-pvcs-api.sh`)

| Error / log | Likely cause | What to try |
|-------------|--------------|-------------|
| `oc/kubectl not available` (WARN) | Cluster CLI missing for optional checks | Install `oc` or `kubectl`; restore may still submit to PPDM |
| `RESTORE_TYPE=... ignored` (WARN) | Non-`TO_EXISTING` type requested | Expected — script always uses `TO_EXISTING` |
| `Submitting Kubernetes PVC restore (POST /api/v2/restored-copies) failed` | PPDM API or payload error | Check HTTP message; verify `copyIds`, `targetInventorySourceId`, and PVC names |
| `Restore request accepted but no activity ID` | Unexpected API response | Check PPDM version and API permissions |

---

## Security notes

- Run `./ppdm-env-check.sh` before restore scripts; credentials live in `.ppdm-env.cfg` (gitignored, mode `600`).
- Prefer interactive password prompts over exporting `PPDM_PASSWORD` in shell history.
- Do not log or share `PPDM_TOKEN` — treat it like a password.
- Remove the env file when finished:

```bash
rm -f .ppdm-env.cfg
unset PPDM_PASSWORD PPDM_TOKEN
```

---

## Quick reference

```bash
# Full interactive flow
cd ppdm-k8s-pvc-restore
./ppdm-env-check.sh
./pvc_restore_wrapper.sh
```

For script-level technical details, see the repository [README.md](../README.md).
