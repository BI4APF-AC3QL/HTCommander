# Windows 自动测试版

仓库的 `Windows test release` Actions 工作流会在 `main` 和 `improve/**` 分支的 `src/**` 或工作流文件变更时自动运行，也支持手动运行。仅在 BI4APF-AC3QL/HTCommander 仓库启用发布。

流程：安装锁定依赖 → 静态检查 → 全量 Flutter 测试 → Windows x64 Release 和 hosted Web UI 编译 → 打包运行库 → 上传 Artifact → 发布 GitHub 预发布 Release。失败时不发布。每次成功运行生成独立 `test-windows-<run-id>-<attempt>` 标签，测试版不标记为最新正式版本，也不触发原有 `v*` 正式发布流程。同分支的新提交会取消尚未完成的旧任务。

在仓库 Releases 中下载 `HTCommander-Windows-x64-test-<commit>.zip`，完整解压并运行 `htcommander.exe`。包含 DLL、data、Visual C++ 运行库、Web UI 和提交标识。`SHA256SUMS.txt` 提供校验值。Actions Artifact 另保留 14 天；Release 附件不会因此过期。

测试包未经代码签名，应用内版本号仍沿用 pubspec；请用包名和 TEST-BUILD.txt 中的提交识别版本。测试版与原版可能共享既有设置，试用前备份设置，不要同时让两个实例连接同一电台。N7500 实际蓝牙丢包率和长时间音频连续性仍需实机验证。

地图页面菜单 → 地图源，可选择 Esri 街道/卫星图、CARTO 或自定义 XYZ。自定义源须使用 WGS84/Web Mercator，GCJ-02 瓦片尚未转换。切换后若没有该源缓存，请关闭离线模式再加载。各地图服务能否访问取决于当地网络。
