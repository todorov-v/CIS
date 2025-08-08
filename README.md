Download
curl -fsSL -o  install_vault_rhel9.sh https://raw.githubusercontent.com/todorov-v/CIS/main/install_vault_rhel9.sh
chmod +x install_vault_rhel9.sh

Quick usage examples
1) Fast lab (HTTP + file storage):

sudo ENABLE_TLS=false STORAGE_BACKEND=file ./install_vault_rhel9.sh
2) TLS (self-signed) + RAFT (good starting point for HA):

sudo ENABLE_TLS=true GENERATE_SELF_SIGNED=true STORAGE_BACKEND=raft ./install_vault_rhel9.sh
3) TLS with your own cert:
sudo ENABLE_TLS=true GENERATE_SELF_SIGNED=false \
  TLS_CERT_FILE=/etc/vault.d/tls/my.crt \
  TLS_KEY_FILE=/etc/vault.d/tls/my.key \
  ./install_vault_rhel9.sh
