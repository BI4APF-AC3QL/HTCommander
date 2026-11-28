# Windows IPv6 公网访问配置

适用于只有公网 IPv6、域名为 `bi4apf.asia`、HTCommander 网页服务端口为 `18080` 的情况。

## 一次配置

1. 在域名 DNS 中设置 `AAAA` 记录指向这台 Windows 电脑当前可从公网访问的 IPv6 地址。若存在失效的 `A` 记录，请删除或修正。
2. 在 Windows 防火墙、路由器及网络运营商侧允许入站 **TCP 443**。本转发器不使用 TCP 80，因此不受 Windows 的 80 端口保留影响。证书申请使用 TLS-ALPN，也需要公网 TCP 443 可达。
3. 打开 HTCommander，在“设置 → 服务端 → 手机远程操控设置”启用网页服务，端口填 `18080`，设置登录密码，并将外网地址填为 `https://bi4apf.asia` 后保存。
4. 完全退出旧版公网转发器。运行 `BI4APF-HTTPS-Gateway-v4.exe`，域名填 `bi4apf.asia`、后端端口填 `18080`，点击“启动入口”。
5. 用手机流量访问 `https://bi4apf.asia`，确认能看到 HTCommander 登录页并登录。

## 网页显示“正在重连”时

- 确认 Windows 上的 HTCommander 仍在运行，且网页服务开关仍开启。
- 在这台电脑访问 `http://127.0.0.1:18080`。本机也无法打开时，问题在 HTCommander 网页服务或端口设置；先恢复本机服务，再启动转发器。
- 打开转发器的“数据目录”，查看 `gateway.log`。证书申请失败时，优先检查 AAAA 地址是否正确、TCP 443 是否真正从公网到达本机，以及 Windows 系统时间是否准确。
- 若本机页面正常、外网页面仍无法打开，检查 IPv6 入站防火墙/运营商策略和 DNS AAAA 记录。公网的 `18080` 无需开放，只让转发器在本机连接它。

转发器只转发网页和 WebSocket，不会代替 HTCommander 运行，也不会修改发射权限。不要把 `HTCommander-Gateway-Data` 里的证书私钥发给他人。
