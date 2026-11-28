# HTCommander HTTPS Gateway

Portable Windows 10/11 x64 WinForms launcher with embedded official Caddy 2.11.4. Configure your DNS hostname and the local HTCommander HTTP port (default 18080), then click Start. No domain or user credential is bundled. Configuration and certificate storage live next to the EXE in `HTCommander-Gateway-Data`.

The gateway preserves Host, supports WebSockets, and uses `Referrer-Policy: same-origin` to keep browser form origins valid. This version serves HTTPS on TCP 443 only, disables the HTTP-to-HTTPS listener, and uses the ACME TLS-ALPN challenge; it does not bind TCP 80. That avoids Windows port-80 reservations when the domain is served over IPv6. Before starting Caddy it checks whether the configured local HTCommander port accepts connections, which helps diagnose a remote page stuck reconnecting.

For an IPv6-only domain, publish a working AAAA record and allow inbound TCP 443 in Windows Firewall and the router/ISP path. Remove stale A records. Start HTCommander web service first and use the same backend port in this launcher. The gateway does not rewrite request Origin, bypass login, enable radio transmit, or modify firewall/router rules. Closing the window stops its Caddy process; it does not configure startup or a Windows service.

Build on Windows with built-in .NET Framework and PowerShell:

```powershell
./tools/https-gateway/build.ps1
```

The script downloads the pinned official Caddy ZIP, verifies its SHA512, embeds the compressed EXE, compiles an x64 launcher, and checks domain validation and Caddy configuration adaptation without binding public ports. Output: `tools/https-gateway/build/HTCommander-HTTPS-Gateway.exe`.

Source uses the repository Apache 2.0 license. Caddy's Apache 2.0 license is shipped as `CADDY-LICENSE.txt`. The executable is unsigned. See [简单配置方法](../../简单配置方法.md).
