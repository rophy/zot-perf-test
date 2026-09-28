#!/bin/bash
set -euxo pipefail

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
cat > /etc/security/limits.d/90-bench.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF

dnf install -y jq python3 tar gzip rsync

# --- k6
dnf install -y "https://github.com/grafana/k6/releases/download/${k6_version}/k6-${k6_version}-linux-amd64.rpm"

# --- crane
curl -fsSL "https://github.com/google/go-containerregistry/releases/download/${crane_version}/go-containerregistry_Linux_x86_64.tar.gz" \
  | tar -xz -C /usr/local/bin crane

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

# --- prometheus
mkdir -p /opt/prometheus /var/lib/prometheus /etc/prometheus
curl -fsSL "https://github.com/prometheus/prometheus/releases/download/v${prometheus_version}/prometheus-${prometheus_version}.linux-amd64.tar.gz" \
  | tar -xz -C /opt/prometheus --strip-components=1
cat > /etc/prometheus/prometheus.yml <<'EOF'
${prometheus_yml}
EOF
cat > /etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=prometheus
[Service]
ExecStart=/opt/prometheus/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=30d --web.enable-remote-write-receiver
Restart=always
[Install]
WantedBy=multi-user.target
EOF

cat >> /etc/environment <<'EOF'
K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write
K6_PROMETHEUS_RW_TREND_STATS="p(50),p(95),p(99),max"
EOF

install -d -o ec2-user -g ec2-user /home/ec2-user/ccdn /tmp/ccdn-results
systemctl daemon-reload
systemctl enable --now node_exporter prometheus
touch /var/local/bootstrap-done
