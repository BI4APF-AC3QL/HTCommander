# Login address QR and connection diagnostics

In Windows, open **Settings → Servers → Phone remote control settings → Address QR and connection diagnostics**. The dialog uses the **saved** origin and backend port. Save changes before reopening it; unsaved text does not change the QR or probe target.

Select the public HTTPS login address or an IPv4 LAN address, then scan its QR from the phone. The QR contains only `/login` and the address/port, never the remote password or a login token. `127.0.0.1` is for checking on the Windows host itself. Enter the password on the phone's login page. The current backend listens on IPv4; an IPv6 public connection uses the configured HTTPS gateway/domain. A raw IPv6 literal is correctly bracketed by the address model, and tested by the independent QR decoder; it is not advertised as a currently listening LAN backend.

**Check saved connection settings** runs four read-only checks, with no password or cookie sent:

| Check | Meaning and next step |
|---|---|
| Local web backend | Requests `http://127.0.0.1:<saved port>/login`. It must recognize the HTCommander login form, not merely get HTTP 200. Unreachable: enable the web service/check its port. Unexpected service: another program or wrong proxy may own the port. |
| DNS A / AAAA | Resolves the configured public host using this PC's resolver and shows IPv4/IPv6 counts. IPv6 only requires IPv6 on the phone network; resolution does not prove inbound connectivity. |
| HTTPS certificate | Native TLS verifies chain, hostname and validity against the normal trust store. A rejected certificate stays rejected; no bypass or trust-store changes. Shows expiry UTC when validation succeeds. Check certificate, hostname and system time on failure. |
| Public login page | Requests the configured HTTPS `/login` and identifies the form. HTTP 502 points to gateway/backend service or port mismatch. HTTP redirects are not followed, and other service pages are not reported as ready. |

The four checks run once per button press. They have an overall five-second bound, native timeouts, 16 KiB response cap and forced HTTP/socket cleanup on completion or dialog close. A repeated click cannot create concurrent runs. Late/disposed results are suppressed. Checks do not open firewall ports, configure certificates, sign in, connect a radio or transmit.

Results are from the Windows host. Still test from the phone's actual network. A router that does not support public-address loopback can make the host's public check fail while a phone on mobile data succeeds. DNS cache and split DNS can also differ between devices.

**Copy redacted connection diagnostics JSON** includes check time, fixed result codes, A/AAAA counts, HTTP status and certificate expiry only. It excludes addresses, exception text, certificate subjects/keys, passwords, cookies, CSRF values and response bodies. Copying the login address is a separate explicit button.

## Acceptance

Seven tests validate saved URL/port restrictions and IPv6 formatting, credential-free QR payloads, timeout/concurrency/disposal, no external probes when no public origin is saved, redacted exports, a real loopback backend's login/other-service/oversized/502/timeout cases, and a real native TLS connection rejecting a synthetic self-signed localhost certificate without a trust bypass. HTTP requests contain no Authorization or Cookie header.

The 390px host widget's **actual rendered QR pixels** for HTTPS and an IPv6 literal are decoded by an independent ZXing decoder. The parent editor test verifies that editing the port without saving still uses the saved target. The synthetic public certificate/key fixtures exist only for isolated loopback tests and are never installed or used by the application.

At this checkpoint the complete 533-test Flutter suite, static analysis and mobile script pass. No real RF/PTT/beacon test or actual phone camera scan was performed.
