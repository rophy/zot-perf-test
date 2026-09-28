#!/bin/bash
set -euxo pipefail

# --- network tuning (identical on both nodes)
cat > /etc/sysctl.d/90-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
fs.file-max = 2097152
EOF
sysctl --system

dnf install -y jq xfsprogs

# --- dedicated EBS data volume -> /var/lib/zot (XFS, mounted by UUID so it survives stop/start)
# On Nitro, EBS volumes are NVMe devices whose serial is the volume id; the data volume is the
# EBS disk with no partitions and nothing mounted (the root volume has partitions).
for _ in $(seq 1 60); do
  dev=$(lsblk -dpno NAME,MODEL,TYPE | awk '/Elastic Block Store/ && $NF=="disk" {print $1}' \
        | while read -r d; do [ "$(lsblk -no NAME "$d" | wc -l)" = 1 ] && echo "$d"; done | head -1)
  [ -n "$dev" ] && break
  sleep 2
done
test -b "$dev"
blkid "$dev" >/dev/null || mkfs.xfs -f "$dev"
uuid=$(blkid -s UUID -o value "$dev")
mkdir -p /var/lib/zot
echo "UUID=$uuid /var/lib/zot xfs defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount /var/lib/zot

# --- zot
curl -fsSL -o /usr/local/bin/zot \
  "https://github.com/project-zot/zot/releases/download/${zot_version}/zot-linux-amd64"
chmod +x /usr/local/bin/zot
mkdir -p /etc/zot
cat > /usr/local/bin/zot-render-config <<'EOF'
${render_config}
EOF
chmod +x /usr/local/bin/zot-render-config
UPSTREAM_URL="https://${ecr_registry}" CREDENTIAL_HELPER=ecr /usr/local/bin/zot-render-config > /etc/zot/config.json
cat > /etc/systemd/system/zot.service <<'EOF'
${zot_service}
EOF

# --- node_exporter
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${node_exporter_version}/node_exporter-${node_exporter_version}.linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin --strip-components=1 "node_exporter-${node_exporter_version}.linux-amd64/node_exporter"
cat > /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=node_exporter
[Service]
ExecStart=/usr/local/bin/node_exporter
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now node_exporter zot
touch /var/local/bootstrap-done
