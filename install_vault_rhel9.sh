#!/usr/bin/env bash
# install_vault_rhel9.sh
# Installs and configures HashiCorp Vault on RHEL 9.
# Options are controlled via ENV vars or inline edits below.

set -euo pipefail

### ======= Config (edit as needed) =======

# Bind address and port
VAULT_BIND_ADDR="${VAULT_BIND_ADDR:-0.0.0.0}"
VAULT_PORT="${VAULT_PORT:-8200}"

# Enable TLS? (true/false)
ENABLE_TLS="${ENABLE_TLS:-false}"

# If ENABLE_TLS=true, set cert/key paths. If empty and self-signed enabled, they’ll be created.
TLS_CERT_FILE="${TLS_CERT_FILE:-/etc/vault.d/tls/vault.crt}"
TLS_KEY_FILE="${TLS_KEY_FILE:-/etc/vault.d/tls/vault.key}"

# Generate a quick self-signed cert if no cert/key provided (dev/lab only!)
GENERATE_SELF_SIGNED="${GENERATE_SELF_SIGNED:-true}"
SELF_SIGNED_CN="${SELF_SIGNED_CN:-vault.local}"
SELF_SIGNED_DAYS="${SELF_SIGNED_DAYS:-825}"

# Storage backend: "file" or "raft"
STORAGE_BACKEND="${STORAGE_BACKEND:-file}"

# UI enabled?
ENABLE_UI="${ENABLE_UI:-true}"

# Open firewall port automatically? (requires firewalld)
OPEN_FIREWALL="${OPEN_FIREWALL:-true}"

### ======= Derived values =======
IP_AUTO="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_SHORT="$(hostname -s)"
SCHEME=$([ "$ENABLE_TLS" = "true" ] && echo "https" || echo "http")
API_ADDR="${API_ADDR:-$SCHEME://$IP_AUTO:$VAULT_PORT}"
CLUSTER_ADDR="${CLUSTER_ADDR:-$SCHEME://$IP_AUTO:8201}"

VAULT_USER="vault"
VAULT_DIR="/etc/vault.d"
VAULT_DATA="/var/lib/vault"
VAULT_CFG="$VAULT_DIR/vault.hcl"
TLS_DIR="$(dirname "$TLS_CERT_FILE")"

### ======= Helpers =======
log() { echo -e "\033[1;32m[+] $*\033[0m"; }
warn() { echo -e "\033[1;33m[!] $*\033[0m"; }
err() { echo -e "\033[1;31m[-] $*\033[0m" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then err "Run as root (sudo)."; exit 1; fi
}

check_rhel9() {
  if ! grep -qi "release 9" /etc/redhat-release 2>/dev/null && \
     ! (grep -qi "rhel" /etc/os-release && grep -qi "VERSION_ID=\"9" /etc/os-release); then
    warn "This script is intended for RHEL 9. Continuing anyway..."
  fi
}

### ======= Steps =======
require_root
check_rhel9

log "Installing HashiCorp repo & Vault..."
dnf -y install yum-utils curl jq >/dev/null
yum-config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo >/dev/null
dnf -y install vault >/dev/null

log "Creating user and directories..."
id -u "$VAULT_USER" &>/dev/null || useradd --system --home "$VAULT_DIR" --shell /sbin/nologin "$VAULT_USER"
mkdir -p "$VAULT_DIR" "$VAULT_DATA"
chown -R "$VAULT_USER:$VAULT_USER" "$VAULT_DIR" "$VAULT_DATA"
chmod 750 "$VAULT_DIR" "$VAULT_DATA"

if [[ "$ENABLE_TLS" = "true" ]]; then
  log "TLS requested."
  mkdir -p "$TLS_DIR"
  if [[ ! -f "$TLS_CERT_FILE" || ! -f "$TLS_KEY_FILE" ]]; then
    if [[ "$GENERATE_SELF_SIGNED" = "true" ]]; then
      log "Generating self-signed TLS cert for CN=$SELF_SIGNED_CN (lab use only)."
      openssl req -x509 -nodes -newkey rsa:4096 \
        -keyout "$TLS_KEY_FILE" -out "$TLS_CERT_FILE" \
        -subj "/CN=$SELF_SIGNED_CN" -days "$SELF_SIGNED_DAYS" >/dev/null 2>&1 || {
          err "OpenSSL failed generating self-signed cert."; exit 1;
        }
      chmod 640 "$TLS_KEY_FILE"
      chown -R "$VAULT_USER:$VAULT_USER" "$TLS_DIR"
    else
      err "ENABLE_TLS=true but TLS cert/key not found at $TLS_CERT_FILE / $TLS_KEY_FILE"
      exit 1
    fi
  else
    log "Using existing TLS cert/key."
    chown -R "$VAULT_USER:$VAULT_USER" "$TLS_DIR"
    chmod 640 "$TLS_KEY_FILE"
  fi
fi

log "Writing Vault configuration to $VAULT_CFG..."
if [[ -f "$VAULT_CFG" ]]; then
  cp -a "$VAULT_CFG" "${VAULT_CFG}.bak.$(date +%s)"
fi

# Build storage block
if [[ "$STORAGE_BACKEND" = "raft" ]]; then
  STORAGE_BLOCK=$(cat <<EOF
storage "raft" {
  path    = "$VAULT_DATA"
  node_id = "$HOST_SHORT"
}
EOF
)
else
  STORAGE_BLOCK=$(cat <<'EOF'
storage "file" {
  path = "/var/lib/vault"
}
EOF
)
fi

# Build listener block
if [[ "$ENABLE_TLS" = "true" ]]; then
  LISTENER_BLOCK=$(cat <<EOF
listener "tcp" {
  address       = "${VAULT_BIND_ADDR}:${VAULT_PORT}"
  tls_disable   = 0
  tls_cert_file = "${TLS_CERT_FILE}"
  tls_key_file  = "${TLS_KEY_FILE}"
}
EOF
)
else
  LISTENER_BLOCK=$(cat <<EOF
listener "tcp" {
  address     = "${VAULT_BIND_ADDR}:${VAULT_PORT}"
  tls_disable = 1
}
EOF
)
fi

# UI flag
UI_LINE=$([ "$ENABLE_UI" = "true" ] && echo "ui = true" || echo "ui = false")

# api/cluster addr lines (recommended esp. for raft/HA)
EXTRA_ADDRS=$(cat <<EOF
api_addr     = "$API_ADDR"
cluster_addr = "$CLUSTER_ADDR"
EOF
)

cat > "$VAULT_CFG" <<EOF
# Managed by install_vault_rhel9.sh
${STORAGE_BLOCK}

${LISTENER_BLOCK}

${UI_LINE}

${EXTRA_ADDRS}
EOF

chown "$VAULT_USER:$VAULT_USER" "$VAULT_CFG"
chmod 640 "$VAULT_CFG"

log "Enabling and starting vault service..."
systemctl daemon-reload
systemctl enable vault >/dev/null
systemctl restart vault

sleep 1
systemctl --no-pager --full status vault || true

if [[ "$OPEN_FIREWALL" = "true" ]]; then
  if systemctl is-active --quiet firewalld; then
    log "Opening TCP ${VAULT_PORT}/tcp in firewalld..."
    firewall-cmd --add-port=${VAULT_PORT}/tcp --permanent >/dev/null || true
    firewall-cmd --reload >/dev/null || true
  else
    warn "firewalld not active; skipping firewall open."
  fi
fi

log "Vault installed."
echo
echo "Next steps:"
echo "1) Export VAULT_ADDR: export VAULT_ADDR='${SCHEME}://127.0.0.1:${VAULT_PORT}'"
echo "2) Initialize Vault (writes unseal keys + root token): vault operator init"
echo "3) Unseal with 3 keys (default): vault operator unseal (repeat)"
echo "4) Login: vault login <ROOT_TOKEN>"
echo
echo "UI: ${SCHEME}://<server-ip>:${VAULT_PORT}"
if [[ "$ENABLE_TLS" = "true" && "$GENERATE_SELF_SIGNED" = "true" ]]; then
  echo "Note: Using a self-signed cert. Your browser/CLI will warn unless you trust the cert."
fi
if [[ "$STORAGE_BACKEND" = "raft" ]]; then
  echo "RAFT storage enabled. For HA, join more nodes with 'vault operator raft join'."
fi
