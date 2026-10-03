#!/usr/bin/env bash
# Install Harbor (plain HTTP, no Trivy) inside the bench VM. Run as root in the VM.
# Usage: install-harbor.sh <version> <hostname/ip> <admin-password-file>
set -euo pipefail
VER="${1:?version e.g. v2.15.2}" HOST="${2:?hostname or ip}" PWFILE="${3:?admin password file}"
cd /opt
if [[ ! -d harbor ]]; then
  curl -fsSL "https://github.com/goharbor/harbor/releases/download/$VER/harbor-online-installer-$VER.tgz" | tar -xz
fi
cd harbor
cp harbor.yml.tmpl harbor.yml
# hostname, plain HTTP on 80, drop the https block, admin password, data dir.
sed -i "s/^hostname: .*/hostname: $HOST/" harbor.yml
sed -i '/^https:/,/^\s*private_key:/ s/^/#/' harbor.yml
sed -i "s/^harbor_admin_password: .*/harbor_admin_password: $(cat "$PWFILE")/" harbor.yml
sed -i "s#^data_volume: .*#data_volume: /data#" harbor.yml
./install.sh
