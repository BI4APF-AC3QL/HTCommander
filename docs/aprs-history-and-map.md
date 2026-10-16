# APRS history, remote maps and browser acceptance

## Result

The remote conversation and station map now restore from the host's existing SQLite RF packet capture and APRS-IS history when Windows starts. Phone reconnects receive the same host-owned view. History decoding updates the view directly: it cannot acknowledge a saved message, enqueue a gateway transfer or request transmission. Loading an old ACK cannot complete a current delivery.

Conversations retain the latest 100 local incoming/outgoing messages by timestamp, deduplicate matching numbered RF/IS copies within five minutes, and use monotonic IDs within a host run. Search/reply/page-local unread remain available. Changing the local callsign rebuilds the relevant conversation. Historical delivery requests/retries are never resumed after restart.

The station index keeps at most 512 stations and 16 timestamped fixes per station. RF/IS history merges in chronological order, including when a live fix arrives first; the newest fix remains current. Positions older than 24 hours or more than five minutes in the future are omitted. Remote snapshots also enforce expiry when no further packets arrive. Returned track copies cannot mutate the host's index. Remote message/map timestamps include UTC offsets.

Clearing APRS removes the phone views and persisted RF APRS/IS records; unrelated packet capture channels are retained. An IS load or aprs.fi backfill already in progress cannot restore records deleted by a later clear.

## Remote tile source configuration

Windows **Map tab menu → Map source** selects OpenStreetMap, Esri street/imagery, CARTO or a configured XYZ URL. Existing provider policies and coordinate requirements apply: use Web Mercator tiles with WGS84 overlays. A provider requiring a token must supply an authorized URL; changing source does not bypass a provider's restrictions.

Authenticated mobile clients now obtain tiles through `/remote-tiles/…` on the same Windows service. The phone receives a source identifier and version digest rather than the custom provider URL/token. The upstream URL is controlled by Windows settings and cannot be supplied by a remote request. This supports a host-accessible HTTP custom source behind a public HTTPS entrance without browser mixed content. Built-in sources use HTTPS. The host makes requests with an identifying HTCommander User-Agent.

The host keeps at most 64 in-memory tiles for ten minutes, with at most eight active fetches, a five-second fetch deadline and a 256 KiB per-tile limit. Identical in-flight requests share a fetch. Redirects, non-success responses, unsupported MIME types and invalid image signatures are rejected without returning upstream errors or credentials. Stop/rebind closes upstream clients. Phone tile requests have their existing 64-cache/eight-load limits. No offline/disk tile cache is added.

On the phone choose a map source, use zoom/drag and station search, and select a station to fill the APRS target. **Retry map** clears the phone cache/error count. If the map shows a provider restriction image or fails, change source or configure an authorized XYZ service on Windows. A successfully downloaded image does not prove that a provider supplied useful geographic tiles.

## Position confirmation

Choose **Get phone position** (browser consent required) or **Preview radio position**. Acquisition only creates a draft. Select **Preview this position**, inspect the coordinates/source, then choose **Confirm this position** or cancel. The inline preview expires after 30 seconds; duplicate confirmation, lost control, permission revocation, stale position or backgrounding prevent submission. The host independently validates position age/accuracy and transmit permissions. Submission is not RF delivery evidence.

## Verification

- Full Flutter suite: 493 tests passed; static analysis and the mobile script passed.
- New file-based SQLite close/reopen test exercises production RF/IS stores and handler startup. Confirms conversation/position recovery, duplicate removal, expired position omission, no transmission/ACK side effects, and selective durable clear followed by another reopen.
- Pending IS-load clear race, live-before-history merge, changed callsign filtering, bounded newest conversation retention, deep track copy isolation and silent-period expiry tests passed.
- Real loopback tile proxy tests cover authentication, configured-source restriction, token/URL exclusion from phone snapshots, cache/concurrency limits, slow upstream timeout, close cancellation, redirects, invalid bodies and oversized images.
- Real 390×844 browser against the production HTTP/WebSocket handler restored SQLite history and verified search/reply/unread. Position preview/cancel/confirm produced one simulated request and one simulated transmit-frame event. No physical radio was connected.
- A 512-station fixture yielded a 256-station viewport response and visible clusters; controls remained usable. A host PCM tap fed a simulated 1 kHz tone to the actual browser's FFT/waterfall at the bounded display cadence. Playback stop cleared scheduled audio in script tests.
- A separate synthetic HTTP XYZ grid, configured on Windows, appeared through the authenticated same-origin proxy in the real browser. Source selection, retry and zoom worked. This verifies the configured-source path, not universal availability of public providers. During direct-provider checks, some public sources returned restriction images or failed, so no public-provider reachability guarantee is made.

No user HTCommander/HTTPS process was stopped. No physical RF/PTT/beacon test was performed. Real phone location permission, real microphone checks, long-running N7500 Bluetooth load testing and the other incomplete ledger entries remain.
