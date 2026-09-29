# Local per-core runs (temporary)

Host: see env.json in each run dir. zot cap = number of pinned CPU threads (GOMAXPROCS = same). Stats = steady-state averages.

| time (UTC) | zot cpus | mode | class | VUs | MB/s | Gbps | pulls/s | p50 ms | p99 ms | fail % | zot cores / cap | zot RSS MB | zot net Gbps | disk rd IOPS | disk wr IOPS | disk rd MB/s | k6 CPU % | run dir |
|---|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 01:16 | 4,5 | http | 10MB | 1 | 1532 | 12.3 | 125.1 | 7 | 19 | 0 | 1.09 / 2 | 167 | 13.3 | 5 | 146 | 0.4 | 63 | 20260929T011531Z-local-http-1c (INVALID: host load spike 10.6) |
| 03:59 | 4,5 | http | 10MB | 1 | 2292 | 18.3 | 187.2 | 5 | 8 | 0 | 1.35 / 2 | 167 | 18.4 | 0 | 74 | 0 | 21 | 20260929T035856Z-local-http-1c |
| 04:00 | 4,5 | http | 10MB | 2 | 3079 | 24.6 | 251.5 | 8 | 13 | 0 | 1.93 / 2 | 168 | 24.7 | 0 | 74 | 0 | 23 | 20260929T035940Z-local-http-1c |
| 04:10 | 4 | http | 10MB | 1 | 1920 | 15.4 | 156.8 | 6 | 10 | 0 | 0.91 / 1 | 162 | 15.4 | 1 | 75 | 0 | 18 | 20260929T041008Z-local-http-cpu4 |
| 04:11 | 4 | http | 10MB | 2 | 2086 | 16.7 | 170.4 | 12 | 19 | 0 | 0.98 / 1 | 163 | 16.8 | 0 | 81 | 0 | 18 | 20260929T041054Z-local-http-cpu4 |
| 04:15 | 4,6 | http | 10MB | 2 | 3931 | 31.5 | 321.1 | 6 | 12 | 0 | 1.76 / 2 | 166 | 31.5 | 13 | 83 | 0.1 | 33 | 20260929T041428Z-local-http-cpu4_6 |
| 04:15 | 4,6 | http | 10MB | 4 | 4334 | 34.7 | 354 | 11 | 25 | 0 | 1.91 / 2 | 167 | 35.1 | 1 | 77 | 0 | 33 | 20260929T041514Z-local-http-cpu4_6 |
| 04:23 | 4,6,8 | http | 10MB | 4 | 6115 | 48.9 | 499.4 | 8 | 16 | 0 | 2.77 / 3 | 164 | 49.2 | 0 | 73 | 0 | 48 | 20260929T042238Z-local-http-cpu4_6_8 |
| 04:24 | 4,6,8 | http | 10MB | 6 | 6343 | 50.7 | 518 | 11 | 23 | 0 | 2.88 / 3 | 164 | 51.2 | 0 | 90 | 0 | 49 | 20260929T042324Z-local-http-cpu4_6_8 |
| 04:25 | 4 | http | 100MB | 1 | 2295 | 18.4 | 23.6 | 43 | 56 | 0 | 0.98 / 1 | 164 | 18.5 | 0 | 67 | 0 | 16 | 20260929T042429Z-local-http-cpu4 |
| 04:26 | 4 | http | 1GB | 1 | 2537 | 20.3 | 2.7 | 356 | 659 | 0 | 0.99 / 1 | 165 | 20.7 | 0 | 70 | 0 | 16 | 20260929T042515Z-local-http-cpu4 |
