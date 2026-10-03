# 原生浏览器权限、麦克风与 PWA 验收

2026-10-03 使用独立 Chromium/Edge 测试配置、390 × 844 视口及生产 HTTP 登录/WebSocket/APRS handler。后端只存在合成电台数据，未构造真实电台、蓝牙运输或实际射频发射设备。

## 已完成的软件路径

- 默认只读客户端可以打开本机麦克风测试；浏览器原生 fake-media 输入测得峰值/RMS/削波，停止与十秒时限结束后输入轨道为 ended。没有麦克风二进制上行，也没有 PTT start 请求。页面截图及无横向溢出验证通过。
- 浏览器原生 geolocation 许可设为 denied 时显示定位失败，后端零帧。设为 granted 后取得合成坐标，获取本身不发送；只读时不能预览发送。
- Windows 仅允许位置操作、保持语音和 APRS 消息关闭，授权操作权后位置预览/取消仍零帧。紧急停止使待确认草稿失效；恢复后重新获取、预览与显式确认才产生一个生产 handler 的模拟帧请求。
- 现有协议回归覆盖坐标/精度/新鲜度、主机电台位置匹配、独立许可撤销和任务标签取消。生产页面脚本同时验证迟到麦克风许可、拒绝、超时、后台/失焦/离开停止、合成 50% 电平与削波。

## PWA 发现与修正

发现浏览器的 manifest 加载器未携带登录 Cookie，得到登录 HTML 后报 `manifest-parsing-or-network-error`；此前直接带 Cookie 的 HTTP 200 测试不足以发现这个问题。现将 manifest 链接设置为 `crossorigin="use-credentials"`，保留 manifest、worker 和图标的登录保护。

Windows 构建虚拟机上的 [验收运行 37117784225](https://github.com/BI4APF-AC3QL/HTCommander/actions/runs/37117784225) 使用 Playwright 1.62.1 锁定的完整 Chrome for Testing 151.0.7922.34，实际浏览器窗口通过：

- 从当前已登录页面安装 PWA，选择浏览器原生“在窗口中打开”偏好，再用原生启动命令打开已安装应用。
- 新应用窗口地址为 `/remote.html`，正常取得客户端状态，`display-mode: standalone` 为 true。没有使用 CSS 模拟独立窗口。
- 浏览器 manifest 解析及安装检查无错误，实际解码 192/512 图标，核对尺寸与 HTTP 200；390px 视口的页面滚动宽度为 375px，无横向溢出或 pageerror。
- 全屏进入/退出成功；测试后卸载应用、关闭浏览器并清理独立配置。验收 JSON、独立窗口及麦克风截图保存在该运行的 `remote-browser-acceptance` artifact，并已检查。

此前 Edge 153 的原生启动命令失败，完整 Chrome 的默认 DevTools 安装偏好则打开普通标签；这些运行没有发布包，也没有被记为通过。当前门禁使用锁定的完整 Chrome、原生用户窗口偏好和实际窗口断言，不以已安装记录或 headless 结果替代窗口验收。此分支的自动 Windows 测试发布先执行此门禁。复现方法见 [浏览器验收工具](https://github.com/BI4APF-AC3QL/HTCommander/tree/feature/remote-aprs-dashboard/tools/browser-acceptance)。

## 实际设备的范围

上述测试使用浏览器原生权限机制和合成媒体/定位数据，不使用真实麦克风、不证明手机 GPS 精度或 RF 交付。手机上仍应允许麦克风后看输入表，允许定位后核对草稿，以及从主屏幕启动并登录；接收与诊断可以先测，不必为验收做真实发射。后台可能暂停收听，PTT 和本机麦克风测试均会停止。
