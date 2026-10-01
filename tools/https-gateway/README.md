# HTCommander HTTPS Gateway

Portable Windows 10/11 x64 WinForms launcher with embedded official Caddy 2.11.4. Configure your DNS hostname and the local HTCommander HTTP port (default 18080), then click Start. No domain or user credential is bundled. Configuration and certificate storage live next to the EXE in `HTCommander-Gateway-Data`.

The gateway preserves Host, supports WebSockets, and uses `Referrer-Policy: same-origin` to keep browser form origins valid. It does not rewrite request Origin, bypass login, enable radio transmit, or modify firewall/router rules. Closing the window stops its Caddy process; it does not configure startup or a Windows service.

Build on Windows with built-in .NET Framework and PowerShell:

```powershell
./tools/https-gateway/build.ps1
```

The script downloads the pinned official Caddy ZIP, verifies its SHA512, embeds the compressed EXE, compiles an x64 launcher, and checks domain validation and Caddy configuration adaptation without binding public ports. Output: `tools/https-gateway/build/HTCommander-HTTPS-Gateway.exe`.

Source uses the repository Apache 2.0 license. Caddy's Apache 2.0 license is shipped as `CADDY-LICENSE.txt`. The executable is unsigned. See [简单配置方法](../../简单配置方法.md).
