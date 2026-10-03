# VM runs (temporary)

VM: multipass, Ubuntu 24.04, 4 vCPU (unpinned), 8 GiB. k6 on the host. Registry CPU = busy vCPUs of the whole VM; memory = VM used memory (total - available). Stats = steady-state averages.

| time (UTC) | registry | class | VUs | MB/s | Gbps | pulls/s | p50 ms | p99 ms | fail % | VM cores busy / vCPUs | VM mem used MB | VM net tx Gbps | disk rd IOPS | disk wr IOPS | host CPU % | run dir |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 14:23 | harbor | 10MB | 1 | 169 | 1.4 | 13.8 | 70 | 115 | 0 | 2.32 / 4 | 1012 | 1.4 | 0 | 188 | 37 | 20261003T142259Z-vm-harbor |
| 14:26 | registry2-control | 10MB | 1 | 723 | 5.8 | 59 | 16 | 37 | 0 | 2.11 / 4 | 687 | 5.8 | 0 | 1 | 41 | 20261003T142548Z-vm-registry2-control |
| 14:27 | registry2-control | 10MB | 2 | 907 | 7.3 | 74.1 | 25 | 50 | 0 | 2.63 / 4 | 704 | 7.2 | 0 | 1 | 45 | 20261003T142631Z-vm-registry2-control |
| 14:27 | registry2-control | 10MB | 4 | 1113 | 8.9 | 90.9 | 42 | 78 | 0 | 2.86 / 4 | 699 | 8.9 | 0 | 1 | 45 | 20261003T142715Z-vm-registry2-control |
| 14:29 | harbor | 10MB | 2 | 239 | 1.9 | 19.5 | 101 | 154 | 0 | 2.93 / 4 | 888 | 1.9 | 0 | 261 | 37 | 20261003T142858Z-vm-harbor |
| 14:30 | harbor | 10MB | 4 | 286 | 2.3 | 23.4 | 168 | 245 | 0 | 3.46 / 4 | 914 | 2.3 | 0 | 313 | 41 | 20261003T142941Z-vm-harbor |
| 14:31 | harbor | 10MB | 8 | 334 | 2.7 | 27.2 | 293 | 395 | 0 | 3.77 / 4 | 966 | 2.7 | 0 | 353 | 42 | 20261003T143025Z-vm-harbor |
| 14:56 | zot | 10MB | 1 | 1229 | 9.8 | 100.3 | 9 | 22 | 0 | 1.32 / 4 | 697 | 9.7 | 0 | 9 | 35 | 20261003T145524Z-vm-zot |
| 14:56 | zot | 10MB | 2 | 1464 | 11.7 | 119.5 | 16 | 35 | 0 | 1.52 / 4 | 701 | 11.6 | 0 | 1 | 38 | 20261003T145607Z-vm-zot |
| 14:57 | zot | 10MB | 4 | 1679 | 13.4 | 137.1 | 28 | 56 | 0 | 1.59 / 4 | 706 | 13.7 | 0 | 1 | 38 | 20261003T145650Z-vm-zot |
| 14:58 | zot | 10MB | 8 | 1978 | 15.8 | 161.5 | 46 | 107 | 0 | 1.76 / 4 | 712 | 16.2 | 0 | 1 | 40 | 20261003T145733Z-vm-zot |
| 14:59 | zot | 10MB | 16 | 2210 | 17.7 | 180.5 | 83 | 203 | 0 | 1.9 / 4 | 737 | 17.9 | 0 | 1 | 40 | 20261003T145824Z-vm-zot |
| 14:59 | zot | 10MB | 32 | 2200 | 17.6 | 179.7 | 154 | 471 | 0 | 1.94 / 4 | 787 | 18.3 | 0 | 1 | 39 | 20261003T145907Z-vm-zot |
