global:
  scrape_interval: 5s
scrape_configs:
  - job_name: zot
    static_configs:
      - targets: ["${zot_ip}:5000"]
  - job_name: node
    static_configs:
      - targets: ["${zot_ip}:9100"]
        labels: { role: zot }
      - targets: ["localhost:9100"]
        labels: { role: client }
