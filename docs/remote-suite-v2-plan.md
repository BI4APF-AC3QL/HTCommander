# Remote suite v2: complete scope and acceptance ledger

Goal: implement every item in the agreed feature list and publish a reviewable PR and test release. This ledger records evidence, not a declaration of completion.

| # | Requirement | Completion evidence required | Status |
|---|---|---|---|
| 1 | Remote APRS messaging, ACK, bounded retry and timeout | Browser send path plus simulated ACK/reject/timeout/retry tests | Pending |
| 2 | Separate voice/message/position permissions and emergency stop | Host UI, server checks, unauthorized-command and revocation tests | Pending |
| 3 | APRS gateway reconnect, backoff, dedup, queue limits and expiry | Fake-network disconnect/overload/expiry tests and gateway metrics | Pending |
| 4 | RF/IS transfer controls, forbidden paths and loop/rate safeguards | Forwarding matrix tests and host configuration | Pending |
| 5 | Link diagnostics, latency/audio backlog/counters and failure causes | Real data sources, browser panel and tests | Pending |
| 6 | APRS conversations, replies, unread, ACK and search | Host/mobile synchronization and browser verification | Pending |
| 7 | Radio/consented-phone position packets with freshness/accuracy | Validation, independent permission and browser consent path | Pending |
| 8 | Lightweight remote map, stations/tracks/source/search/message action | Browser interaction and map-state tests | Pending |
| 9 | Map clustering, viewport limits, throttling/cache limits/staleness | Load/update/cap tests and browser verification | Pending |
| 10 | Audio spectrum/waterfall with bounded remote traffic | Known-tone DSP test and live simulated PCM browser visualization | Pending |
| 11 | Audio buffers/recovery/input meters/clipping/mic test | DSP/buffer tests and browser verification | Pending |
| 12 | Client list, targeted revocation and read-only/control roles | Authentication/authorization/revocation isolation tests | Pending |
| 13 | Remote radio/gateway/activity dashboard | Verified server telemetry and phone layout | Pending |
| 14 | Host-configured beacon tasks, pause and explicit resume authorization | Scheduler/time/permission/cancellation tests and UI | Pending |
| 15 | Address QR and DNS/certificate/backend diagnostics | QR decoding and diagnostic failure tests | Pending |
| 16 | Configuration export/import excluding secrets/private keys, preview | Roundtrip/validation/redaction tests and UI | Pending |
| 17 | Redacted logs and disconnected simulation mode | Sensitive-data tests, simulated ACK/disconnect/RX and visible UI | Pending |
| 18 | Phone home-screen app and responsive/full-screen controls | Manifest/install assets, browser layout; background limitation documented | Pending |
| 19 | GitHub PR, build/release and simple usage docs | Actual PR state, passing CI and verified release contents | Pending |

Spectrum means received **audio** spectrum. RF-wide spectrum needs hardware/SDR data not supplied by N7500 and is not claimed. No development test performs real RF transmission. These boundaries preserve the original feature list.
