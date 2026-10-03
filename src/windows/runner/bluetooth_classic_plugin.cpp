// Copyright 2026 Ylian Saint-Hilaire - Apache 2.0
//
// Windows Bluetooth Classic (RFCOMM) plugin using WinRT
// Windows.Devices.Bluetooth.Rfcomm + Windows.Networking.Sockets.StreamSocket
//
// Implements the same MethodChannel / EventChannel contract as the macOS
// BluetoothClassicHandler (IOBluetooth / Swift), so the Dart wrapper
// BluetoothClassicMacOS works on Windows without any Dart-side changes.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
// GetCurrentTime is a Win32 macro that conflicts with WinRT internals.
#ifdef GetCurrentTime
#undef GetCurrentTime
#endif

// C++/WinRT headers from the Windows SDK.
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Bluetooth.Rfcomm.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Sockets.h>
#include <winrt/Windows.Storage.Streams.h>
#include <winrt/Windows.System.h>

// Standard library.
#include <atomic>
#include <map>
#include <deque>
#include <condition_variable>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <algorithm>

// Flutter Desktop C++ wrapper.
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include "bluetooth_classic_plugin.h"
#include "bluetooth_receive_queue.h"

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------
namespace {

// WinRT namespace aliases.
namespace bt     = winrt::Windows::Devices::Bluetooth;
namespace rfcomm = winrt::Windows::Devices::Bluetooth::Rfcomm;
namespace denum  = winrt::Windows::Devices::Enumeration;
namespace radios = winrt::Windows::Devices::Radios;
namespace socks  = winrt::Windows::Networking::Sockets;
namespace strs   = winrt::Windows::Storage::Streams;
namespace wf     = winrt::Windows::Foundation;

// Service UUIDs -----------------------------------------------------------

// SPP / GAIA control channel.
const winrt::guid kSppUuid{
    0x00001101, 0x0000, 0x1000,
    {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};

// BS AOC vendor service — carries SBC audio on these radios (ch 2).
// See docs/radio-bluetooth.md.
const winrt::guid kBsAocUuid{
    0x39144315, 0x32FA, 0x40DB,
    {0x85, 0xED, 0xFB, 0xFE, 0xBA, 0x2D, 0x86, 0xE6}};

// Generic Audio fallback (0x1203).
const winrt::guid kGenericAudioUuid{
    0x00001203, 0x0000, 0x1000,
    {0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB}};

// Convert "AA:BB:CC:DD:EE:FF" (or with '-') to uint64_t.
uint64_t ParseMac(const std::string& addr) {
  std::string s;
  for (char c : addr) {
    if (c != ':' && c != '-') s += c;
  }
  return std::stoull(s, nullptr, 16);
}

// Convert uint64_t to "AA:BB:CC:DD:EE:FF".
std::string FormatMac(uint64_t addr) {
  char buf[18];
  snprintf(buf, sizeof(buf), "%02X:%02X:%02X:%02X:%02X:%02X",
           static_cast<int>((addr >> 40) & 0xFF),
           static_cast<int>((addr >> 32) & 0xFF),
           static_cast<int>((addr >> 24) & 0xFF),
           static_cast<int>((addr >> 16) & 0xFF),
           static_cast<int>((addr >> 8) & 0xFF),
           static_cast<int>(addr & 0xFF));
  return buf;
}

// WinRT hstring → UTF-8 std::string.
std::string HstrToStr(const winrt::hstring& hs) {
  if (hs.empty()) return "";
  auto wstr = std::wstring_view(hs);
  int n = WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                              static_cast<int>(wstr.size()),
                              nullptr, 0, nullptr, nullptr);
  if (n <= 0) return "";
  std::string s(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wstr.data(),
                      static_cast<int>(wstr.size()),
                      &s[0], n, nullptr, nullptr);
  return s;
}

// ---------------------------------------------------------------------------
// Active RFCOMM connection state
// ---------------------------------------------------------------------------
// Disable replies before Flutter's messenger is destroyed. The lock only
// covers the short channel reply, never a Bluetooth/WinRT operation.
struct BtReplyGate {
  std::mutex mutex;
  bool enabled = true;
  void Disable() { std::lock_guard<std::mutex> lock(mutex); enabled = false; }
  template <typename Result>
  void Success(const Result& result, const flutter::EncodableValue& value) {
    std::lock_guard<std::mutex> lock(mutex);
    if (enabled) result->Success(value);
  }
};

struct RfcommConn {
  socks::StreamSocket socket{nullptr};
  strs::DataReader    reader{nullptr};
  strs::DataWriter    writer{nullptr};
  std::string         address;
  std::atomic<bool>   running{false};
  std::thread         read_thread;
  std::shared_ptr<BtReplyGate> replies;
  using Result = flutter::MethodResult<flutter::EncodableValue>;
  struct WriteRequest {
    std::vector<uint8_t> bytes;
    std::shared_ptr<Result> result;
  };
  std::mutex write_mutex;
  std::condition_variable write_ready;
  std::deque<WriteRequest> writes;
  std::thread write_thread;

  void Stop() {
    running.store(false);
    write_ready.notify_all();
    try { if (socket) socket.Close(); } catch (...) {}
  }

  static void StopInBackground(std::shared_ptr<RfcommConn> conn) {
    // Called by the platform-thread disconnect handlers. Closing a WinRT
    // socket can wait on the Bluetooth driver, especially during link loss.
    // Mark the connection unusable immediately, but never close it on the UI
    // thread. Retain it until Close finishes so the destructor also stays on
    // the worker (unless a read/write worker still owns it).
    conn->running.store(false);
    conn->write_ready.notify_all();
    std::thread([conn = std::move(conn)]() mutable {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      conn->Stop();
      conn.reset();
      winrt::uninit_apartment();
    }).detach();
  }

  void QueueWrite(std::vector<uint8_t> data, std::unique_ptr<Result> result) {
    {
      std::lock_guard<std::mutex> lock(write_mutex);
      if (!running.load() || writes.size() >= 256) {
        result->Success(flutter::EncodableValue(false));
        return;
      }
      writes.push_back({std::move(data), std::shared_ptr<Result>(std::move(result))});
    }
    write_ready.notify_one();
  }

  static void StartWriter(const std::shared_ptr<RfcommConn>& conn) {
    // One persistent FIFO worker per channel replaces a thread per write.
    // Control and audio remain independent, so audio cannot starve commands.
    conn->write_thread = std::thread([conn]() {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      while (true) {
        WriteRequest request;
        {
          std::unique_lock<std::mutex> lock(conn->write_mutex);
          conn->write_ready.wait(lock, [&] {
            return !conn->running.load() || !conn->writes.empty();
          });
          if (conn->writes.empty()) break;
          request = std::move(conn->writes.front());
          conn->writes.pop_front();
        }
        bool ok = false;
        if (conn->running.load()) {
          try {
            conn->writer.WriteBytes(request.bytes);
            auto operation = conn->writer.StoreAsync();
            if (operation.wait_for(std::chrono::seconds(5)) ==
                winrt::Windows::Foundation::AsyncStatus::Completed) {
              ok = operation.GetResults() == request.bytes.size();
            } else {
              operation.Cancel();
            }
          } catch (...) {}
          // A stalled/partial write leaves stream framing uncertain. Close it
          // instead of replaying potentially non-idempotent transmit commands.
          if (!ok) { try { conn->socket.Close(); } catch (...) {} }
        }
        conn->replies->Success(request.result, flutter::EncodableValue(ok));
      }
      winrt::uninit_apartment();
    });
  }

  RfcommConn() = default;
  ~RfcommConn() {
    running.store(false);
    try {
      if (socket) socket.Close();
    } catch (...) {}
    write_ready.notify_all();
    if (read_thread.joinable()) read_thread.detach();
    if (write_thread.joinable()) write_thread.detach();
  }
  RfcommConn(const RfcommConn&) = delete;
  RfcommConn& operator=(const RfcommConn&) = delete;
};

// ---------------------------------------------------------------------------
// Thread-safe event stream handler that marshals events to the platform thread
//
// Flutter platform channel messages must be delivered on the platform (UI)
// thread. RFCOMM reads happen on background threads, so we cannot call
// EventSink::Success directly from there. The Flutter Windows platform thread
// runs a Win32 message loop (it has no WinRT DispatcherQueue), so we create a
// message-only window on that thread when the stream is listened to and post a
// drain message to it from background threads. The window procedure runs on the
// platform thread and delivers the queued events safely.
// ---------------------------------------------------------------------------
class BtStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  BtStreamHandler() = default;
  ~BtStreamHandler() override { DestroyMessageWindow(); }

  // Platform-thread only. Waiting readers retain this handler, but cannot use
  // its Flutter sink or HWND after shutdown. Never wait for a driver here.
  void Shutdown() {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
    sink_.reset();
    pending_events_.Clear();
    space_ready_.notify_all();
    DestroyMessageWindow();
  }

  bool Send(const std::string& type, const std::string& address,
            const std::vector<uint8_t>* data,
            const std::atomic<bool>* running = nullptr,
            const std::string& reason = {}, bool* overloaded = nullptr) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (overloaded) *overloaded = false;
    if (stopping_) return false;
    if (type == "connected") {
      if (!pending_events_.Begin(address)) return false;
    } else if (type == "disconnected") {
      pending_events_.End(address, reason);
      space_ready_.notify_all();
    } else if (type == "data" && data) {
      // Only reader workers enter this branch. Brief backpressure preserves
      // the byte stream during a UI stall without growing an unbounded queue.
      // A sustained stall ends the connection; control bytes are never silently
      // dropped while leaving a parser attached to the rest of that stream.
      const auto deadline = std::chrono::steady_clock::now() +
                            std::chrono::seconds(1);
      if (data->size() > BluetoothReceiveQueue::kMaxChunk) {
        if (overloaded) *overloaded = true;
        return false;
      }
      while (!pending_events_.CanPush(address, data->size())) {
        if (stopping_ || !pending_events_.IsOpen(address) ||
            (running && !running->load())) return false;
        if (space_ready_.wait_until(lock, deadline) == std::cv_status::timeout &&
            !pending_events_.CanPush(address, data->size())) {
          if (overloaded) *overloaded = true;
          return false;
        }
      }
      if (running && !running->load()) return false;
      if (!pending_events_.Push(address, *data)) return false;
    } else {
      return false;
    }
    ScheduleDrainLocked();
    return true;
  }

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue*,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
          events) override {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_ = std::move(events);

    // OnListen runs on the platform thread, so create the marshaling window
    // here to give it platform-thread affinity.
    EnsureMessageWindow();

    // Drain any events that accumulated before the listener was attached.
    ScheduleDrainLocked();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue*) override {
    std::lock_guard<std::mutex> lock(mutex_);
    sink_ = nullptr;
    pending_events_.Clear();
    space_ready_.notify_all();
    if (message_hwnd_) ::KillTimer(message_hwnd_, kDrainTimer);
    drain_posted_ = false;
    return nullptr;
  }

 private:
  static constexpr UINT kDrainMessage = WM_USER + 0x42;
  static constexpr UINT_PTR kDrainTimer = 1;

  std::mutex mutex_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  BluetoothReceiveQueue pending_events_;
  std::condition_variable space_ready_;
  bool stopping_ = false;
  bool drain_posted_ = false;
  HWND message_hwnd_ = nullptr;

  void ScheduleDrainLocked(bool yield_to_input = false) {
    if (!sink_ || !message_hwnd_ || drain_posted_ || pending_events_.empty()) return;
    // Posted messages outrank keyboard/mouse input in the Windows loop. A
    // continuously reposted drain could starve input even with a small batch.
    // Use a low-priority timer for successive batches so input/paint can run.
    if (yield_to_input) {
      drain_posted_ = ::SetTimer(message_hwnd_, kDrainTimer, 10, nullptr) != 0;
      if (drain_posted_) return;
    }
    drain_posted_ = ::PostMessageW(message_hwnd_, kDrainMessage, 0, 0) != 0;
  }

  void DrainQueue() {
    // Platform-thread only. Release the reader mutex before encoding/delivering.
    std::vector<BluetoothReceiveQueue::Event> events;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      drain_posted_ = false;
      if (!sink_) return;
      // Bound encoding work as well as storage: at most eight events / 64 KiB
      // per platform turn, rather than up to one MiB in a single message.
      events = pending_events_.Drain();
      space_ready_.notify_all();
      ScheduleDrainLocked(true);
    }
    for (const auto& event : events) {
      if (!sink_) break;
      using EV = flutter::EncodableValue;
      flutter::EncodableMap value;
      value[EV("event")] = EV(event.type);
      value[EV("address")] = EV(event.address);
      if (event.type == "data") value[EV("data")] = EV(event.data);
      if (!event.reason.empty()) value[EV("reason")] = EV(event.reason);
      try { sink_->Success(EV(std::move(value))); } catch (...) {}
    }
  }

  // Must be called on the platform thread (from OnListen).
  void EnsureMessageWindow() {
    if (message_hwnd_) return;
    static const wchar_t* kClassName = L"HTCommanderBtClassicMsgWindow";
    HINSTANCE instance = ::GetModuleHandleW(nullptr);

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &BtStreamHandler::WndProc;
    wc.hInstance = instance;
    wc.lpszClassName = kClassName;
    // Ignore failure if the class is already registered by another handler.
    ::RegisterClassExW(&wc);

    message_hwnd_ = ::CreateWindowExW(
        0, kClassName, L"", 0, 0, 0, 0, 0,
        HWND_MESSAGE, nullptr, instance, this);
  }

  void DestroyMessageWindow() {
    if (message_hwnd_) {
      ::DestroyWindow(message_hwnd_);
      message_hwnd_ = nullptr;
    }
  }

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam) {
    if (msg == WM_NCCREATE) {
      auto* create = reinterpret_cast<CREATESTRUCTW*>(lparam);
      ::SetWindowLongPtrW(hwnd, GWLP_USERDATA,
                          reinterpret_cast<LONG_PTR>(create->lpCreateParams));
      return ::DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    if (msg == kDrainMessage || (msg == WM_TIMER && wparam == kDrainTimer)) {
      if (msg == WM_TIMER) ::KillTimer(hwnd, kDrainTimer);
      auto* self = reinterpret_cast<BtStreamHandler*>(
          ::GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (self) {
        self->DrainQueue();
      }
      return 0;
    }
    return ::DefWindowProcW(hwnd, msg, wparam, lparam);
  }
};

// EventChannel accepts unique ownership; this adapter lets reader workers hold
// the underlying handler safely until they finish. Shutdown destroys its UI
// resources on the platform thread before the adapter/channel are released.
class SharedBtStreamHandler : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  explicit SharedBtStreamHandler(std::shared_ptr<BtStreamHandler> handler)
      : handler_(std::move(handler)) {}
 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(const flutter::EncodableValue* arguments,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& sink) override {
    return handler_->OnListen(arguments, std::move(sink));
  }
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue* arguments) override {
    return handler_->OnCancel(arguments);
  }
 private:
  std::shared_ptr<BtStreamHandler> handler_;
};

}  // namespace

// ---------------------------------------------------------------------------
// Pimpl struct
// ---------------------------------------------------------------------------
struct BluetoothClassicPlugin::Impl : std::enable_shared_from_this<Impl> {
  // Flutter channels.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      method_channel;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      data_event_channel;
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      audio_event_channel;

  std::shared_ptr<BtStreamHandler> data_handler;
  std::shared_ptr<BtStreamHandler> audio_handler;
  std::shared_ptr<BtReplyGate> replies = std::make_shared<BtReplyGate>();

  // Active connections.
  std::mutex conn_mutex;
  std::map<std::string, std::shared_ptr<RfcommConn>> connections;
  std::map<std::string, std::shared_ptr<RfcommConn>> audio_connections;

  // Set to true during destruction to suppress further event dispatches.
  std::atomic<bool> shutdown{false};

  // -------------------------------------------------------------------------
  explicit Impl(flutter::BinaryMessenger* messenger);
  ~Impl() = default;
  void Shutdown();

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Individual handlers — all dispatched to background MTA threads.
  void DoIsAvailable(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoGetPairedDevices(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoFindCompatibleDevices(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoGetDeviceNames(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoConnect(
      const std::string& address,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoDisconnect(
      const std::string& address,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoSend(
      const std::string& address,
      std::vector<uint8_t> data,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoConnectAudio(
      const std::string& address,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoDisconnectAudio(
      const std::string& address,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void DoSendAudio(
      const std::string& address,
      std::vector<uint8_t> data,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Read loop — runs on a background thread per connection.
  void ReadLoop(std::shared_ptr<RfcommConn> conn, bool is_audio);

  // Thread-safe event dispatch.
  bool SendEvent(bool is_audio,
                 const std::string& type,
                 const std::string& address,
                 const std::vector<uint8_t>* data = nullptr,
                 const std::atomic<bool>* running = nullptr,
                 const std::string& reason = {}, bool* overloaded = nullptr);

  // Helper: open an RFCOMM socket for a given service UUID.
  // Returns a fully-connected StreamSocket or throws on failure.
  socks::StreamSocket OpenRfcommSocket(
      uint64_t bt_address,
      std::initializer_list<winrt::guid> service_uuids);

  // Helper: enumerate all paired Classic BT devices.
  flutter::EncodableList GetPairedDeviceList(bool compatible_only);
};

// ---------------------------------------------------------------------------
// Impl constructor / destructor
// ---------------------------------------------------------------------------
BluetoothClassicPlugin::Impl::Impl(flutter::BinaryMessenger* messenger) {
  using EV = flutter::EncodableValue;

  // Method channel.
  method_channel =
      std::make_unique<flutter::MethodChannel<EV>>(
          messenger,
          "com.htcommander/bluetooth_classic",
          &flutter::StandardMethodCodec::GetInstance());
  method_channel->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });

  // Data event channel.
  auto dh = std::make_shared<BtStreamHandler>();
  data_handler = dh;
  data_event_channel =
      std::make_unique<flutter::EventChannel<EV>>(
          messenger,
          "com.htcommander/bluetooth_classic_data",
          &flutter::StandardMethodCodec::GetInstance());
  data_event_channel->SetStreamHandler(
      std::make_unique<SharedBtStreamHandler>(dh));

  // Audio event channel.
  auto ah = std::make_shared<BtStreamHandler>();
  audio_handler = ah;
  audio_event_channel =
      std::make_unique<flutter::EventChannel<EV>>(
          messenger,
          "com.htcommander/bluetooth_classic_audio",
          &flutter::StandardMethodCodec::GetInstance());
  audio_event_channel->SetStreamHandler(
      std::make_unique<SharedBtStreamHandler>(ah));
}

void BluetoothClassicPlugin::Impl::Shutdown() {
  if (shutdown.exchange(true)) return;
  replies->Disable();
  data_handler->Shutdown();
  audio_handler->Shutdown();
  method_channel->SetMethodCallHandler(nullptr);
  method_channel.reset();
  data_event_channel.reset();
  audio_event_channel.reset();

  std::vector<std::shared_ptr<RfcommConn>> stopped;
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    for (auto& entry : connections) stopped.push_back(entry.second);
    for (auto& entry : audio_connections) stopped.push_back(entry.second);
    connections.clear();
    audio_connections.clear();
  }
  for (auto& conn : stopped) RfcommConn::StopInBackground(std::move(conn));
  // Workers hold shared Impl ownership. No fixed sleep or platform-thread
  // socket close; late workers find shutdown set and never touch Flutter.
}

// ---------------------------------------------------------------------------
// Method call dispatcher
// ---------------------------------------------------------------------------
void BluetoothClassicPlugin::Impl::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const auto& method = call.method_name();

  auto GetArg = [&](const char* key) -> const flutter::EncodableValue* {
    const auto* args =
        std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) return nullptr;
    auto it = args->find(flutter::EncodableValue(std::string(key)));
    return it != args->end() ? &it->second : nullptr;
  };

  if (method == "isAvailable") {
    DoIsAvailable(std::move(result));
  } else if (method == "getPairedDevices") {
    DoGetPairedDevices(std::move(result));
  } else if (method == "findCompatibleDevices") {
    DoFindCompatibleDevices(std::move(result));
  } else if (method == "getDeviceNames") {
    DoGetDeviceNames(std::move(result));
  } else if (method == "connect") {
    auto* addr = GetArg("address");
    if (!addr) { result->Error("INVALID_ARGS", "Missing address"); return; }
    DoConnect(std::get<std::string>(*addr), std::move(result));
  } else if (method == "disconnect") {
    auto* addr = GetArg("address");
    if (!addr) { result->Error("INVALID_ARGS", "Missing address"); return; }
    DoDisconnect(std::get<std::string>(*addr), std::move(result));
  } else if (method == "send") {
    auto* addr = GetArg("address");
    auto* data = GetArg("data");
    if (!addr || !data) {
      result->Error("INVALID_ARGS", "Missing address or data"); return;
    }
    DoSend(std::get<std::string>(*addr),
           std::get<std::vector<uint8_t>>(*data),
           std::move(result));
  } else if (method == "connectAudio") {
    auto* addr = GetArg("address");
    if (!addr) { result->Error("INVALID_ARGS", "Missing address"); return; }
    DoConnectAudio(std::get<std::string>(*addr), std::move(result));
  } else if (method == "disconnectAudio") {
    auto* addr = GetArg("address");
    if (!addr) { result->Error("INVALID_ARGS", "Missing address"); return; }
    DoDisconnectAudio(std::get<std::string>(*addr), std::move(result));
  } else if (method == "sendAudio") {
    auto* addr = GetArg("address");
    auto* data = GetArg("data");
    if (!addr || !data) {
      result->Error("INVALID_ARGS", "Missing address or data"); return;
    }
    DoSendAudio(std::get<std::string>(*addr),
                std::get<std::vector<uint8_t>>(*data),
                std::move(result));
  } else {
    result->NotImplemented();
  }
}

// ---------------------------------------------------------------------------
// SendEvent — thread-safe dispatch through an EventChannel sink
// ---------------------------------------------------------------------------
bool BluetoothClassicPlugin::Impl::SendEvent(
    bool is_audio, const std::string& type, const std::string& address,
    const std::vector<uint8_t>* data, const std::atomic<bool>* running,
    const std::string& reason, bool* overloaded) {
  if (shutdown.load()) return false;
  auto handler = is_audio ? audio_handler : data_handler;
  return handler && handler->Send(type, address, data, running, reason, overloaded);
}

// ---------------------------------------------------------------------------
// OpenRfcommSocket helper
// Tries each UUID in order; returns the first successfully connected socket.
// ---------------------------------------------------------------------------
socks::StreamSocket
BluetoothClassicPlugin::Impl::OpenRfcommSocket(
    uint64_t bt_address,
    std::initializer_list<winrt::guid> service_uuids) {

  auto btDevice = bt::BluetoothDevice::FromBluetoothAddressAsync(bt_address)
                      .get();
  if (!btDevice) {
    throw winrt::hresult_error(E_FAIL, L"Device not found");
  }

  rfcomm::RfcommDeviceService service{nullptr};

  for (const auto& uuid : service_uuids) {
    try {
      auto res = btDevice.GetRfcommServicesForIdAsync(
                              rfcomm::RfcommServiceId::FromUuid(uuid),
                              bt::BluetoothCacheMode::Uncached)
                     .get();
      if (res.Error() == bt::BluetoothError::Success &&
          res.Services().Size() > 0) {
        service = res.Services().GetAt(0);
        break;
      }
    } catch (...) {}
  }

  if (!service) {
    // Last resort: first available RFCOMM service.
    auto res = btDevice.GetRfcommServicesAsync(bt::BluetoothCacheMode::Uncached)
                   .get();
    if (res.Error() != bt::BluetoothError::Success ||
        res.Services().Size() == 0) {
      throw winrt::hresult_error(E_FAIL, L"No RFCOMM services found");
    }
    service = res.Services().GetAt(0);
  }

  socks::StreamSocket sock;
  sock.ConnectAsync(
          service.ConnectionHostName(),
          service.ConnectionServiceName(),
          socks::SocketProtectionLevel::
              BluetoothEncryptionAllowNullAuthentication)
      .get();
  return sock;
}

// ---------------------------------------------------------------------------
// GetPairedDeviceList helper
// ---------------------------------------------------------------------------
flutter::EncodableList
BluetoothClassicPlugin::Impl::GetPairedDeviceList(bool compatible_only) {
  flutter::EncodableList list;
  try {
    auto selector =
        bt::BluetoothDevice::GetDeviceSelectorFromPairingState(true);
    auto devices = denum::DeviceInformation::FindAllAsync(selector).get();

    for (const auto& di : devices) {
      try {
        auto btDev = bt::BluetoothDevice::FromIdAsync(di.Id()).get();
        if (!btDev) continue;

        // Identify radios by their unique vendor SDP service UUID ("BS AOC")
        // rather than by name, which changes across rebrands / OS stacks.
        flutter::EncodableList service_uuids;
        try {
          auto res = btDev.GetRfcommServicesForIdAsync(
                              rfcomm::RfcommServiceId::FromUuid(kBsAocUuid),
                              bt::BluetoothCacheMode::Cached)
                         .get();
          if (res.Error() == bt::BluetoothError::Success &&
              res.Services().Size() > 0) {
            service_uuids.push_back(flutter::EncodableValue(
                std::string("39144315-32fa-40db-85ed-fbfeba2d86e6")));
          }
        } catch (...) {}

        if (compatible_only && service_uuids.empty()) continue;

        std::string name    = HstrToStr(btDev.Name());
        std::string address = FormatMac(btDev.BluetoothAddress());

        flutter::EncodableMap dev;
        dev[flutter::EncodableValue("name")]        = flutter::EncodableValue(name);
        dev[flutter::EncodableValue("address")]     = flutter::EncodableValue(address);
        dev[flutter::EncodableValue("isPaired")]    = flutter::EncodableValue(true);
        dev[flutter::EncodableValue("isConnected")] = flutter::EncodableValue(false);
        dev[flutter::EncodableValue("serviceUuids")] =
            flutter::EncodableValue(std::move(service_uuids));
        list.push_back(flutter::EncodableValue(std::move(dev)));
      } catch (...) {}
    }
  } catch (...) {}
  return list;
}

// ---------------------------------------------------------------------------
// Read loop — runs on a background thread
// ---------------------------------------------------------------------------
void BluetoothClassicPlugin::Impl::ReadLoop(
    std::shared_ptr<RfcommConn> conn, bool is_audio) {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);

  bool receive_overload = false;
  while (conn->running.load()) {
    try {
      uint32_t bytes = conn->reader.LoadAsync(4096).get();
      if (bytes == 0) break;  // Remote end closed the connection.

      uint32_t available = conn->reader.UnconsumedBufferLength();
      std::vector<uint8_t> buf(available);
      conn->reader.ReadBytes(buf);

      if (!SendEvent(is_audio, "data", conn->address, &buf, &conn->running,
                     {}, &receive_overload)) {
        break;
      }
    } catch (...) {
      break;  // Socket closed or error.
    }
  }

  // If we exited unexpectedly (i.e., not because the caller set running=false),
  // send a disconnected event and remove from the map.
  bool was_running = conn->running.exchange(false);
  conn->write_ready.notify_all();
  if (was_running) {
    SendEvent(is_audio, "disconnected", conn->address, nullptr, nullptr,
              receive_overload ? "receive_queue_overflow" : "link_closed");
    // Closing a stalled socket stays on a worker, including this error path.
    RfcommConn::StopInBackground(conn);
    std::lock_guard<std::mutex> lock(conn_mutex);
    auto& map = is_audio ? audio_connections : connections;
    auto it = map.find(conn->address);
    if (it != map.end() && it->second.get() == conn.get()) {
      map.erase(it);
    }
  }

  winrt::uninit_apartment();
}

// ---------------------------------------------------------------------------
// Method implementations
// ---------------------------------------------------------------------------

void BluetoothClassicPlugin::Impl::DoIsAvailable(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));

  auto self = shared_from_this();
  std::thread([res, self]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      auto adapter = bt::BluetoothAdapter::GetDefaultAsync().get();
      if (!adapter) {
        self->replies->Success(res, flutter::EncodableValue(false));
        winrt::uninit_apartment();
        return;
      }
      auto radio = adapter.GetRadioAsync().get();
      bool on = radio &&
                radio.State() == radios::RadioState::On;
      self->replies->Success(res, flutter::EncodableValue(on));
    } catch (...) {
      self->replies->Success(res, flutter::EncodableValue(false));
    }
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoGetPairedDevices(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto self = shared_from_this();

  std::thread([res, self]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    self->replies->Success(res, flutter::EncodableValue(self->GetPairedDeviceList(false)));
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoFindCompatibleDevices(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto self = shared_from_this();

  std::thread([res, self]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    self->replies->Success(res, flutter::EncodableValue(self->GetPairedDeviceList(true)));
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoGetDeviceNames(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto self = shared_from_this();

  std::thread([res, self]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    auto list = self->GetPairedDeviceList(false);
    flutter::EncodableList names;
    for (const auto& item : list) {
      const auto& m = std::get<flutter::EncodableMap>(item);
      auto it = m.find(flutter::EncodableValue("name"));
      if (it != m.end()) names.push_back(it->second);
    }
    self->replies->Success(res, flutter::EncodableValue(std::move(names)));
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoConnect(
    const std::string& address,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    if (connections.count(address)) {
      result->Success(flutter::EncodableValue(connections.at(address)->running.load()));
      return;
    }
  }

  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto self = shared_from_this();

  std::thread([self, address, res]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      uint64_t btAddr = ParseMac(address);
      auto sock = self->OpenRfcommSocket(btAddr, {kSppUuid});

      auto conn       = std::make_shared<RfcommConn>();
      conn->address   = address;
      conn->replies   = self->replies;
      conn->socket    = sock;
      conn->reader    = strs::DataReader(sock.InputStream());
      conn->reader.InputStreamOptions(strs::InputStreamOptions::Partial);
      conn->writer    = strs::DataWriter(sock.OutputStream());
      conn->running.store(true);
      RfcommConn::StartWriter(conn);

      bool admitted = false;
      {
        std::lock_guard<std::mutex> lock(self->conn_mutex);
        if (!self->shutdown.load() && !self->connections.count(address)) {
          self->connections[address] = conn;
          admitted = true;
        }
      }
      if (!admitted) {
        RfcommConn::StopInBackground(conn);
        self->replies->Success(res, flutter::EncodableValue(false));
        winrt::uninit_apartment();
        return;
      }

      // Reserve a bounded stream slot and publish connected before any data.
      if (!self->SendEvent(false, "connected", address)) {
        {
          std::lock_guard<std::mutex> lock(self->conn_mutex);
          auto it = self->connections.find(address);
          if (it != self->connections.end() && it->second == conn)
            self->connections.erase(it);
        }
        RfcommConn::StopInBackground(conn);
        self->replies->Success(res, flutter::EncodableValue(false));
        winrt::uninit_apartment();
        return;
      }
      conn->read_thread = std::thread([self, conn]() {
        self->ReadLoop(conn, false);
      });
      self->replies->Success(res, flutter::EncodableValue(true));
    } catch (...) {
      self->replies->Success(res, flutter::EncodableValue(false));
    }
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoDisconnect(
    const std::string& address,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<RfcommConn> conn;
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    auto it = connections.find(address);
    if (it != connections.end()) {
      conn = it->second;
      connections.erase(it);
    }
  }
  if (conn) {
    RfcommConn::StopInBackground(std::move(conn));
    SendEvent(false, "disconnected", address);
  }
  result->Success(flutter::EncodableValue(true));
}

void BluetoothClassicPlugin::Impl::DoSend(
    const std::string& address,
    std::vector<uint8_t> data,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<RfcommConn> conn;
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    auto it = connections.find(address);
    if (it != connections.end()) conn = it->second;
  }
  if (!conn || !conn->running.load()) {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  conn->QueueWrite(std::move(data), std::move(result));
}

void BluetoothClassicPlugin::Impl::DoConnectAudio(
    const std::string& address,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    if (audio_connections.count(address)) {
      result->Success(flutter::EncodableValue(audio_connections.at(address)->running.load()));
      return;
    }
  }

  auto res = std::shared_ptr<
      flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
  auto self = shared_from_this();

  std::thread([self, address, res]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    try {
      uint64_t btAddr = ParseMac(address);
      // Try BS AOC vendor UUID first, fall back to Generic Audio.
      auto sock = self->OpenRfcommSocket(btAddr,
                                         {kBsAocUuid, kGenericAudioUuid});

      auto conn       = std::make_shared<RfcommConn>();
      conn->address   = address;
      conn->replies   = self->replies;
      conn->socket    = sock;
      conn->reader    = strs::DataReader(sock.InputStream());
      conn->reader.InputStreamOptions(strs::InputStreamOptions::Partial);
      conn->writer    = strs::DataWriter(sock.OutputStream());
      conn->running.store(true);
      RfcommConn::StartWriter(conn);

      bool admitted = false;
      {
        std::lock_guard<std::mutex> lock(self->conn_mutex);
        if (!self->shutdown.load() && !self->audio_connections.count(address)) {
          self->audio_connections[address] = conn;
          admitted = true;
        }
      }
      if (!admitted) {
        RfcommConn::StopInBackground(conn);
        self->replies->Success(res, flutter::EncodableValue(false));
        winrt::uninit_apartment();
        return;
      }

      // Reserve a bounded stream slot and publish connected before any data.
      if (!self->SendEvent(true, "connected", address)) {
        {
          std::lock_guard<std::mutex> lock(self->conn_mutex);
          auto it = self->audio_connections.find(address);
          if (it != self->audio_connections.end() && it->second == conn)
            self->audio_connections.erase(it);
        }
        RfcommConn::StopInBackground(conn);
        self->replies->Success(res, flutter::EncodableValue(false));
        winrt::uninit_apartment();
        return;
      }
      conn->read_thread = std::thread([self, conn]() {
        self->ReadLoop(conn, true);
      });
      self->replies->Success(res, flutter::EncodableValue(true));
    } catch (...) {
      self->replies->Success(res, flutter::EncodableValue(false));
    }
    winrt::uninit_apartment();
  }).detach();
}

void BluetoothClassicPlugin::Impl::DoDisconnectAudio(
    const std::string& address,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<RfcommConn> conn;
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    auto it = audio_connections.find(address);
    if (it != audio_connections.end()) {
      conn = it->second;
      audio_connections.erase(it);
    }
  }
  if (conn) {
    RfcommConn::StopInBackground(std::move(conn));
    SendEvent(true, "disconnected", address);
  }
  result->Success(flutter::EncodableValue(true));
}

void BluetoothClassicPlugin::Impl::DoSendAudio(
    const std::string& address,
    std::vector<uint8_t> data,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  std::shared_ptr<RfcommConn> conn;
  {
    std::lock_guard<std::mutex> lock(conn_mutex);
    auto it = audio_connections.find(address);
    if (it != audio_connections.end()) conn = it->second;
  }
  if (!conn || !conn->running.load()) {
    result->Success(flutter::EncodableValue(false));
    return;
  }

  conn->QueueWrite(std::move(data), std::move(result));
}

// ---------------------------------------------------------------------------
// BluetoothClassicPlugin outer class — just delegates to Impl
// ---------------------------------------------------------------------------
BluetoothClassicPlugin::BluetoothClassicPlugin(
    flutter::BinaryMessenger* messenger)
    : impl_(std::make_shared<Impl>(messenger)) {}

BluetoothClassicPlugin::~BluetoothClassicPlugin() { impl_->Shutdown(); }
