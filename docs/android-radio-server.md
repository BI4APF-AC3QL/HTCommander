# Android 电台连接与远控服务器

完成代码和安装包检查后，可按[Android 与电台实机验收清单](android-device-acceptance.md)记录真实手机、电台及后台运行结果。

HTCommander Android 版可直接通过系统蓝牙配对连接支持的电台，也能把同一部手机作为远控主机：应用连接电台后，可在“设置 → 服务端 → 手机远程操控设置”启用网页服务。其他设备在同一 Wi-Fi 内打开页面显示的 Android 本机地址并登录，即可使用手机远控页面；点击“更多 → 完整界面 · 地图/APRS”还可打开与桌面主机相同的 Flutter Web 界面。Android 测试包和正式包都会把该 Web 界面打入 APK。

## 下载 Android 测试版

从 [Android 测试版 Releases](https://github.com/BI4APF-AC3QL/HTCommander/releases) 下载最新预发布版本，包含分架构 APK、AAB 和 SHA256 校验文件；也可从 [Android 构建工作流](https://github.com/BI4APF-AC3QL/HTCommander/actions/workflows/build-android.yaml?query=branch%3Afeature%2Fremote-aprs-dashboard) 的成功运行中下载 `android-apks-by-abi`。APK 只适配对应处理器架构：大多数新手机选 `app-arm64-v8a-release.apk`；较旧的 32 位 ARM 设备选 `app-armeabi-v7a-release.apk`；x86_64 设备或模拟器选 `app-x86_64-release.apk`。AAB 仅用于测试分发流程；当前工件可能使用临时 Android debug 签名，不能作为应用商店发布包。Actions 工件通常保留 90 天，预发布版本可从 Releases 页面持续下载。

当前 CI 测试 APK 使用临时 Android debug 签名，不能保证覆盖商店版或其他签名版本。安装前请保留现有 HTCommander 和本机数据；不要为了安装测试包直接卸载或清除原应用。建议使用备用设备，或先完成单独的数据备份。

Android 的“设置 → 许可证 → 位置”可点“使用本机 GPS 定位”获取一次当前坐标，也可开启“持续使用手机 GPS 定位”。持续定位会更新同一手动位置源，供电台位置、APRS-IS 范围筛选和卫星跟踪共用；启用后会显示 Android 常驻服务通知，并在应用切到后台时继续运行，增加耗电。关闭后保留最后一次坐标。开启持续定位前需授予定位权限；如电台已配置自动信标且允许发送，位置更新可能改变信标内容。

## 首次连接电台

1. 打开电台并启用蓝牙。使用 Bluetooth Classic 的电台（例如 VR-N7500）需先在 Android 系统蓝牙设置中配对；BLE 电台可由 HTCommander 扫描发现。Android 一般依据已配对设备的厂商服务 UUID 识别经典蓝牙电台；若系统尚未缓存 UUID，名称明确为 VR-N7500 或 N7500 的已配对设备仍会显示，最终能否连接要以应用读取到电台状态为准。
2. 打开 HTCommander 并允许蓝牙权限。Android 12 及以上需允许“附近的设备”；较早系统扫描 BLE 时可能还需定位权限。
3. 进入电台连接页面，选择发现的电台并连接。只有应用内显示已连接并取得电台状态后，才表示控制链路建立。Android 会记住用户主动连接过的蓝牙电台；遇到临时断连、蓝牙暂时不可用或启动时电台不在范围内时，会按 2、4、8、16、30、60、120 秒逐步延长重试间隔，之后每 5 分钟继续尝试。此策略只针对仍记住的电台；用户手动断开或取消记忆后会停止重连。等待和执行重试期间，Android 常驻服务会继续运行以维持后台重连能力，不会因此开启网页服务或额外保持 Wi-Fi。
4. Android 版支持系统蓝牙连接和应用现有电台控制、APRS、地图、卫星、音频及日志页面。AGWPE 是可在 Android 上运行的 TCP 网络服务。Android 还可使用 USB OTG 串口 GPS：在设置 → 地图中刷新设备、选择 USB 串口并设定波特率；首次打开时按系统提示授权。支持范围取决于 USB 串口芯片和手机 OTG 供电。USB/串口电台连接仍未接入 Android，不能由 RFCOMM 蓝牙替代。

## Android 接收语音转文字

Android 13 及以上优先使用系统离线语音识别；Android 12 及更早版本、系统没有可用的本机识别器，或系统识别器无法初始化时，64 位 ARM 手机和 x86_64 设备可在“设置 → 通讯 → 语音识别”下载离线模型。模型由用户选择下载，不包含在 APK 中；下载量从数十 MB 到约 1 GB 不等。识别处理接收的电台音频，不保存音频文件。32 位处理器若没有可用的 Android 系统识别器，则不能启用此功能。

## 开启 Android 远控服务器

1. 进入“设置 → 服务端 → 手机远程操控设置”。
2. 开启“允许局域网 / VPN 远程访问”，设置至少 12 位密码。
3. 端口可保留 8080；再开启“启用网页服务”并保存。
4. 页面会显示本机 IPv4 和 IPv6 地址；网络切换后列表自动刷新，也可点“刷新本机地址”。选择另一台设备可访问的地址，在浏览器打开并输入密码。IPv4 示例：`http://192.168.1.24:8080/`；IPv6 地址需加方括号，例如 `http://[240e:1234::25]:8080/`。服务优先监听双栈 IPv6 套接字，同时接受 IPv4；系统禁用 IPv6 时回退为 IPv4。
5. Android 会显示常驻通知并保持服务进程运行。停止时回到相同设置关闭网页服务。此模式需要 Android 保持网络可用，并会增加一些耗电。

局域网 HTTP 可用于登录、收听及控制，但 Android 浏览器会限制非安全页面的麦克风和定位等能力。如需在外网使用，建议接入 VPN 或将 Android 端口经 HTTPS 反向代理发布；不要直接把无 TLS 的 8080 暴露到公网。手机浏览器的麦克风和定位功能需要可信 HTTPS 页面。卫星下行跟踪可由 Android 本机使用观测位置；网页远控的数据范围仍取决于本机与浏览器权限。

## 连接 Home Assistant

Android 版支持与 Windows、Linux、macOS 相同的 Home Assistant MQTT 桥接，可将已连接电台发布到 MQTT Discovery，并从 Home Assistant 控制电台音量、静噪、扫描、双守候和信道。打开“设置 → 服务器 → Home Assistant”，填写 MQTT Broker 地址和账号，点击“测试”后保存并开启桥接。详细的 Mosquitto 与 Home Assistant 设置步骤见 [Home Assistant MQTT 配置指南](blogs/home-assistant-mqtt.md)。

桥接开启且已填写 Broker 地址时，Android 会显示常驻通知并保持后台服务运行，以维持 MQTT 连接；这会增加耗电。连接远端 Broker 时请使用 TLS（通常是 `mqtts://`），不要在不可信网络中明文传输 MQTT 密码。关闭 Home Assistant 桥接后，若没有其他后台功能运行，服务会释放。

从源码本地构建 Android 包时，先运行 `flutter pub get` 和 `python tools/stage_android_web_assets.py --clean`，再运行 `flutter build web --release --base-href / --dart-define=HTC_HOSTED=true --no-wasm-dry-run`，接着运行 `python tools/stage_android_web_assets.py` 和 `python tools/stage_android_web_assets.py --prepare-package`，最后运行 `flutter build apk --release` 或 `flutter build appbundle --release`。完成后运行 `python tools/stage_android_web_assets.py --restore-package` 还原临时修改的 `pubspec.yaml`。清理步骤避免上次打包的 Web 文件被再次嵌入新 Web 构建；显式声明嵌套目录可确保 CanvasKit、地图和插件资源进入 APK；官方 Android CI 和发布工作流会自动执行这些步骤。

## 平台边界

Android 与 Windows 共用 Flutter 电台协议、APRS 处理、地图、频谱、卫星计算、Winlink、远程权限和循环语音录音逻辑。安卓可扫描 BLE 电台，也可通过 Bluetooth Classic RFCOMM 控制已配对电台；VR-N7500 继续使用 Classic。两者可使用电台音频通道。在“音频”页可刷新并选择 Android 当前可用的扬声器、有线、USB 或蓝牙输出路由；移除的设备会回退到系统默认输出。语音识别也处理同一接收音频流，但 Android 使用系统识别或 Android ARM64 离线回退模型。Android 端还可启用远控网页服务、AGWPE TCP 服务和 Home Assistant MQTT 桥接，后台运行时由 Android 常驻通知服务维持。

AGWPE 默认只监听本机回环地址。要让同一可信局域网或 VPN 中的其他设备连接，在“设置 → 服务端”启用 AGWPE 后，再勾选“允许局域网客户端连接”。该协议没有密码保护；不要将 AGWPE 端口直接转发到公网。关闭此选项会恢复本机专用监听。

平台特有项：Android 可使用 USB OTG 串口 GPS；这只用于 GPS 接收器，不提供 USB/串口电台控制。当前项目的电台传输实现没有 USB/串口电台传输或串口电台网关，因此这不是 Android 相对 Windows 的功能缺口。Android 应用通过 APK 或应用商店更新，Windows 则使用桌面更新流程。USB OTG GPS 的芯片兼容、热插拔和定位效果仍需在目标手机与接收器上验收。

连接电台、APRS-IS、EchoLink、AllStarLink、Winlink 同步、网页服务、AGWPE、Home Assistant MQTT、持续手机定位或本机循环录音运行时，Android 显示常驻通知并持有部分唤醒锁；网页服务开启时还会保持 Wi-Fi 活跃，关闭网页服务后释放该锁。Winlink TCP 在短时自动重连间隔也会保持服务运行；取消同步或重试结束后，若没有其他活动任务，服务会释放。Flutter 引擎由应用持有，Activity 退出/任务从最近列表移除时，已启用的网页服务、电台连接和定位事件通道继续在同一 Dart 引擎中运行。断开最后一台电台并关闭其他运行功能后会释放服务。系统强制停止应用或厂商省电策略仍可能中断服务，需在目标手机实测。AGWPE 仅应在可信局域网/VPN中开放；它面向兼容客户端的 TCP 接口不提供远程登录密码保护。

Android 蓝牙接收队列最多缓存 128 个数据块或 512 KiB，并按块投递给 Flutter 主线程。音频积压时丢弃较旧数据以追上实时播放；若发生丢弃，应用日志每 5 秒至多报告一次丢弃块数和字节数。控制数据保持顺序，队列达到上限时断开该 RFCOMM 连接，避免内存持续增长或把缺失字节交给协议解析器。断开原因会以固定代码写入应用日志，包括对端关闭、读取/写入失败和控制队列过载，便于判断是无线链路还是本机处理过载。队列边界单测由 Android 构建流程运行；目标手机上的长时蓝牙负载仍需实机验收。

RFCOMM 连接会逐个尝试已缓存信道、SDP 服务和备用信道；每个系统连接尝试最多等待 8 秒，整轮最多 45 秒。连接成功的固定 RFCOMM 信道会按电台地址和服务类型保存在应用私有设置中，应用或手机重启后仍可优先快速尝试；缓存信道失效时会清除旧值并继续扫描，不需要用户手动重置。超时会关闭当前套接字并继续下一候选，避免连接调用无限等待。弱信号和系统蓝牙栈仍可能造成接近此上限的连接时间；真机速度及重连表现需要在目标电台上验证。

Flutter 引擎退出或重建时，Android 蓝牙桥会注销控制/音频事件通道，关闭已连接和正在连接的 RFCOMM 套接字。这样重新进入应用不会遗留旧的蓝牙连接或事件监听器。
