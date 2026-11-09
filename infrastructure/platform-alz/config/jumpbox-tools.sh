#!/usr/bin/env bash
# Installs the Azure CLI from the Microsoft apt repository. Idempotent; needs only packages.microsoft.com
# and the Ubuntu mirrors. (The aka.ms installer redirects to a blob URL that the firewall allow-list does not cover.)
set -euo pipefail
if command -v az >/dev/null 2>&1; then
  echo "azure-cli already installed: $(az version 2>/dev/null | jq -r '."azure-cli"')"
  exit 0
fi
export DEBIAN_FRONTEND=noninteractive
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg
chmod go+r /etc/apt/keyrings/microsoft.gpg
cat > /etc/apt/sources.list.d/azure-cli.sources <<EOF
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg
EOF
apt-get update -qq
apt-get install -y -qq azure-cli
echo "azure-cli installed: $(az version 2>/dev/null | jq -r '."azure-cli"')"
