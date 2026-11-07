# Windows scheduled APRS beacon task

Windows owns one periodic software beacon task. Configure it under **APRS → Software beacon**. Choose an interval, APRS symbol and up to 60 printable ASCII comment characters. Choose either the specified connected radio's APRS channel, or Internet only through a verified APRS-IS login. A radio task never switches to another radio or to the internet if its destination disappears.

1. Save the configuration. Saving pauses the task and does not send a beacon.
2. Reopen Software beacon. Review the saved task and availability reason.
3. Select **Start / resume task…**, review destination, comment and position disclosure, then **Authorize schedule**. Authorization expires after 30 seconds, and is invalidated by a changed configuration or pause.
4. The first slot waits a full interval. **Pause task** immediately stops future slots and cancels pending beacon-tagged hardware/software modem frames. Other local/gateway frames stay intact.

Startup always waits for new approval. Edits, callsign/SSID changes, emergency stop, RF permission withdrawal or destination disconnection pause the task. Restoring the connection/permission does not resume it. Configuration import also stops the task through its permissions/service shutdown.

Radio slots require **Allow transmit**, the exact configured radio and APRS channel, an observed idle report no older than 15 seconds, and no radio lock. Busy reception/transmission, unknown/stale status and missing/invalid/stale location skip a slot. Position requires a finite valid fix no older than two minutes; a maintained manual host location is supported through the normal location handler. Status-only tasks need a comment. Missed slots after sleep (at least five seconds late) and backward clock changes reschedule a full interval without catch-up or retry.

Internet-only slots use the production APRS-IS manager's verified immediate write path, without an offline/backoff backlog. They do not require an RF uplink gateway or a radio. Write failure/disconnect pauses the task; nothing is replayed on reconnect. Echoed local task frames do not enter the RF heard list or RF-to-IS queue. RF and internet destinations are explicit alternatives for this task.

Phone users see a read-only task panel: running/paused, interval, destination kind, fixed reason, next UTC time and request/skipped counters. They cannot configure, start or resume the task. The full web settings bridge excludes every SoftwareBeacon key. Only an allowlisted payload-free summary goes to the phone; comment, position and approval revision are omitted. Runtime authorization/status never persist.

Counters describe software requests, not RF delivery or APRS ACK. A frame already handed to the radio or written to APRS-IS cannot be undone. This scheduler does not change the radio's separately configured built-in hardware beacon.

## Verification

- Six tests cover production handler startup/edit/approval/disconnect/permission/emergency behavior, strict configuration/privacy, time/clock/suspend scheduling, position/status validation, fake-network verified internet writes and failures, and a 390px host cancel/expired/stale-confirm/approve/pause workflow.
- Production Radio and SoftwareModem cancellation regressions prove only task-tagged queued frames/encoding are cancelled, preserving other traffic. Mock transports and encoders never touch hardware.
- The 33-test targeted scheduler/gateway/queue group passed. The complete 526-test Flutter suite, static analysis and mobile script passed at this checkpoint.
- A real 390px browser connected to production loopback HTTP/WebSocket with simulated radio data: paused → running with next UTC time → emergency paused; no task action buttons, PTT disabled, no horizontal overflow or console errors. No frame request occurred in that browser preview.

No physical radio, PTT or beacon transmission was used in verification. Physical receive/long-duration Windows acceptance remains separate.
