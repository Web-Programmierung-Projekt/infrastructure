#!/usr/bin/env bash
# Idempotent bootstrap for the wohnmobil VM (Debian 12).
#
# Run as root or with sudo. Safe to re-run; each step is conditional on the
# desired state.
#
#   - Installs Docker Engine + the compose plugin.
#   - Installs the Cloud SQL Auth Proxy and registers it as a systemd service.
#   - Configures ufw to drop everything except :22 from the team's allowlist.
#   - Pulls per-environment secrets from GCP Secret Manager into secrets/<env>.env.
#
# Required environment variables:
#   GCP_PROJECT_ID            e.g. wohnmobil-prod
#   CLOUDSQL_INSTANCE         e.g. wohnmobil-prod:europe-west3:wohnmobil-postgres
#   ALLOWED_SSH_CIDRS         comma-separated, e.g. "1.2.3.4/32,5.6.7.8/32"
#
# Usage:
#   sudo GCP_PROJECT_ID=... CLOUDSQL_INSTANCE=... ALLOWED_SSH_CIDRS=... ./bootstrap-vm.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "bootstrap-vm.sh must be run as root (use sudo)." >&2
    exit 1
fi

: "${GCP_PROJECT_ID:?GCP_PROJECT_ID must be set}"
: "${CLOUDSQL_INSTANCE:?CLOUDSQL_INSTANCE must be set}"
: "${ALLOWED_SSH_CIDRS:?ALLOWED_SSH_CIDRS must be set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { printf '[bootstrap] %s\n' "$*"; }

# ── 1. System packages ────────────────────────────────────────────────────────
log "Updating apt index and installing base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release ufw

# ── 2. Docker Engine + compose plugin ─────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    log "Installing Docker Engine"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y --no-install-recommends \
        docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
else
    log "Docker already installed; skipping"
fi

# Allow the deploy user (created by GCE OS Login) to run docker without sudo.
# The convention is to use the SSH login name; adjust if your team has a fixed
# deploy account.
DEPLOY_USER="${SUDO_USER:-${USER}}"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
    usermod -aG docker "$DEPLOY_USER" || true
fi

# ── 3. Cloud SQL Auth Proxy ───────────────────────────────────────────────────
PROXY_BIN=/usr/local/bin/cloud-sql-proxy
if [[ ! -x "$PROXY_BIN" ]]; then
    log "Installing Cloud SQL Auth Proxy"
    curl -fsSL "https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.13.0/cloud-sql-proxy.linux.amd64" \
        -o "$PROXY_BIN"
    chmod +x "$PROXY_BIN"
fi

cat > /etc/systemd/system/cloud-sql-proxy.service <<EOF
[Unit]
Description=Cloud SQL Auth Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${PROXY_BIN} --address 0.0.0.0 --port 5432 --private-ip ${CLOUDSQL_INSTANCE}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cloud-sql-proxy

# ── 4. Firewall ───────────────────────────────────────────────────────────────
log "Configuring ufw (allow only :22 from the configured CIDRs)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
IFS=',' read -ra cidrs <<< "$ALLOWED_SSH_CIDRS"
for cidr in "${cidrs[@]}"; do
    ufw allow from "${cidr}" to any port 22 proto tcp
done
ufw --force enable

# ── 5. Pull per-environment secrets from Secret Manager ───────────────────────
log "Materialising secrets/<env>.env from Secret Manager"
mkdir -p "${REPO_ROOT}/secrets"
chmod 700 "${REPO_ROOT}/secrets"

if ! command -v gcloud >/dev/null 2>&1; then
    log "Installing google-cloud-sdk"
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    apt-get update -y
    apt-get install -y google-cloud-sdk
fi

for env in dev test prod; do
    secret_name="${env}-env"
    target="${REPO_ROOT}/secrets/${env}.env"
    # Use `versions access` directly as the gate — the VM SA has
    # secretAccessor (which grants .access) but typically not the broader
    # .get permission that `secrets describe` requires. Fetch into a temp
    # file so we never leave a truncated target on failure.
    tmp=$(mktemp)
    if gcloud secrets versions access latest --secret "$secret_name" --project "$GCP_PROJECT_ID" \
            > "$tmp" 2>/dev/null; then
        mv "$tmp" "$target"
        chmod 600 "$target"
        log "  wrote ${target}"
    else
        rm -f "$tmp"
        log "  WARNING: secret ${secret_name} not found or not accessible in ${GCP_PROJECT_ID}; skipping ${target}"
    fi
done

# Append cross-environment secrets (currently just the Resend API key for
# transactional email). They live as separate Secret Manager entries so a
# rotation doesn't require regenerating an entire <env>-env blob.
#
# If the secret is missing, the backend treats RESEND_API_KEY as unset and
# logs every send to stdout — see app/core/email.py.
log "Appending cross-environment secrets"
for env in test prod; do
    target="${REPO_ROOT}/secrets/${env}.env"
    [[ -f "$target" ]] || continue
    # Strip any previous RESEND_API_KEY / EMAIL_FROM lines so this script
    # stays idempotent when run on a host whose env files were already
    # populated by an earlier bootstrap.
    sed -i '/^RESEND_API_KEY=/d; /^EMAIL_FROM=/d' "$target"
    # Same `versions access` direct fetch as above. Captures into a local
    # to avoid leaving a bare RESEND_API_KEY= line if the fetch fails.
    if resend_key=$(gcloud secrets versions access latest --secret "resend-api-key" \
            --project "$GCP_PROJECT_ID" 2>/dev/null); then
        {
            echo ""
            echo "# Transactional email — appended by bootstrap-vm.sh from Secret Manager"
            echo "RESEND_API_KEY=${resend_key}"
            echo "EMAIL_FROM=Freiheit <onboarding@resend.dev>"
        } >> "$target"
        chmod 600 "$target"
        log "  appended Resend config to ${target}"
    else
        log "  WARNING: resend-api-key not found in ${GCP_PROJECT_ID}; ${env} stays in stdout-only mode"
    fi
done

log "Bootstrap complete."
