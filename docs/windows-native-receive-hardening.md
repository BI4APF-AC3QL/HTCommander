# Windows 蓝牙接收积压与退出生命周期

本次继续检查 Windows + N7500 的整窗“未响应”。已确认原生接收队列没有总容量上限，退出时也仅等待固定 100 毫秒后释放后台任务仍可能使用的对象。这是可从代码验证的风险；目前没有用户现场挂起堆栈，不能据此认定实际卡死根因。

## 修改后的行为

- 控制与音频各自拥有接收队列，单队列最多保存 512 KiB 数据和 128 个数据事件；单事件最多 32 KiB。同一地址的相邻数据合并，保持字节顺序。
- 单队列最多保留 32 个连接或尚未交付的断开通知。连接建立时预留终止通知容量，连接通知先于读取开始；超出容量的连接返回失败。
- 队列暂时满时，仅后台读取线程等待，最多 1 秒。界面恢复处理后，继续交付完整字节流。Windows 主线程不等待队列空间。
- 持续过载时，终止相应连接并报告 `receive_queue_overflow`。未交付的该连接数据随连接结束清理，不继续用缺字节的旧协议解析器，也不自动重放发送请求。其他连接数据保持顺序。
- 每次 Windows 消息处理最多交付 8 个事件、64 KiB 数据，减少一次突发处理的工作量。
- 退出时立即禁用后续回复，在 Windows 主线程释放蓝牙桥接使用的 Flutter sink 和消息窗口，后台关闭蓝牙 socket。后台任务持有共享对象，完成后再释放；移除了固定 100 毫秒等待和退出路径的主线程 socket 关闭。

这些限制约束的是**原生接收与平台事件交付**。它们不表示 Flutter isolate、系统蓝牙驱动和所有下游缓冲都有统一内存上限。仍需要真实 N7500 长时间接收与发生未响应时的调用栈验证。

## 已执行的验证

两个 C++ 测试程序使用生产队列和生产 Windows 消息处理器，无蓝牙发现、socket、电台或发射操作：

1. 字节/事件/连接容量、百万次拒绝输入、不同连接顺序、终止通知预留、重连及清空。
2. 真实 Win32 消息窗口、短暂拥堵恢复后完整交付、持续拥堵后单次断开、新连接重新接收、等待中退出立即唤醒，以及禁用后 100,000 次迟到回复均不访问 Flutter messenger。

本地 MSVC Release 编译采用应用的 C++17、异常/警告配置，两个原生测试通过；相关 10 项 Flutter 蓝牙/卡顿回归测试、`flutter analyze` 和手机脚本通过。当前分支先前的全量 493 项 Flutter 测试已通过；新提交由 CI 再验证全量测试。Windows 发布流程新增原生测试，失败时不打包发布。

## 接收复测

解压对应提交的整个 Windows 测试 ZIP，运行 `htcommander.exe`。先只连接电台接收，然后依次加入 APRS-IS、地图和手机收听，每次只增加一项。记录故障时间、Windows 是否显示未响应、CPU/内存变化和蓝牙断开信息。若出现接收队列过载提示，说明保护已触发，不等同于已确认故障原因；取消的请求不会自动重放。

## 开发者复现

平台无关容量测试可用 C++17 编译 `src/windows/tests/bluetooth_receive_queue_test.cpp`。Windows 完整测试需要 Flutter 已构建的 wrapper 与运行时：

```powershell
cmake -S src/windows/tests -B build/native-tests `
  -DFLUTTER_EPHEMERAL_DIR=<src/windows/flutter/ephemeral 的绝对路径> `
  -DFLUTTER_WRAPPER_LIBRARY=<flutter_wrapper_app.lib 的绝对路径>
cmake --build build/native-tests --config Release
ctest --test-dir build/native-tests -C Release --output-on-failure
```

自动 Windows 测试发行流程配置了这些路径，可在 Actions 中查看实际运行结果。
