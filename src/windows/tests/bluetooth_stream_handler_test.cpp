// Exercises the production marshaling window/queue with synthetic bytes only.
// No RFCOMM sockets, radio discovery or transmission are invoked.
#include "../runner/bluetooth_classic_plugin.cpp"
#include "../runner/engine_owned_native_plugin.h"
#include <cstdlib>
#include <iostream>

void Check(bool condition) { if (!condition) std::abort(); }
struct Capture {
  size_t bytes = 0;
  size_t connected = 0;
  size_t disconnected = 0;
  std::string reason;
};
class TestSink : public flutter::EventSink<flutter::EncodableValue> {
 public:
  explicit TestSink(Capture& capture) : capture_(capture) {}
 protected:
  void SuccessInternal(const flutter::EncodableValue* value) override {
    Check(value != nullptr);
    const auto& map = std::get<flutter::EncodableMap>(*value);
    using EV = flutter::EncodableValue;
    const auto& type = std::get<std::string>(map.at(EV("event")));
    if (type == "data") {
      for (auto byte : std::get<std::vector<uint8_t>>(map.at(EV("data")))) {
        Check(byte == 42);
        ++capture_.bytes;
      }
    } else if (type == "connected") {
      ++capture_.connected;
    } else if (type == "disconnected") {
      ++capture_.disconnected;
      auto reason = map.find(EV("reason"));
      if (reason != map.end()) capture_.reason = std::get<std::string>(reason->second);
    }
  }
  void ErrorInternal(const std::string&, const std::string&,
                     const flutter::EncodableValue*) override { std::abort(); }
  void EndOfStreamInternal() override {}
 private:
  Capture& capture_;
};
void Pump() {
  MSG msg;
  while (::PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    ::TranslateMessage(&msg);
    ::DispatchMessageW(&msg);
  }
}
template <typename Predicate>
void PumpUntil(Predicate ready) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
  while (!ready() && std::chrono::steady_clock::now() < deadline) {
    Pump();
    std::this_thread::sleep_for(std::chrono::milliseconds(1));
  }
  Check(ready());
}
std::shared_ptr<BtStreamHandler> Listen(Capture& capture) {
  auto handler = std::make_shared<BtStreamHandler>();
  handler->OnListen(nullptr, std::make_unique<TestSink>(capture));
  Check(handler->Send("connected", "a", nullptr));
  return handler;
}
int main() {
  struct OwnedNative {
    explicit OwnedNative(flutter::BinaryMessenger*) {}
    ~OwnedNative() { ++Destroyed(); }
    static size_t& Destroyed() { static size_t count = 0; return count; }
  };
  for (size_t i = 0; i < 10000; ++i) {
    std::unique_ptr<flutter::Plugin> owned =
        std::make_unique<EngineOwnedNativePlugin<OwnedNative>>(nullptr);
  }
  Check(OwnedNative::Destroyed() == 10000);
  struct Reply {
    size_t calls = 0;
    void Success(const flutter::EncodableValue&) { ++calls; }
  };
  auto reply = std::make_shared<Reply>();
  auto gate = std::make_shared<BtReplyGate>();
  gate->Success(reply, flutter::EncodableValue(true));
  gate->Disable();
  std::thread late_reply([gate, reply]() {
    for (size_t i = 0; i < 100000; ++i)
      gate->Success(reply, flutter::EncodableValue(true));
  });
  late_reply.join();
  Check(reply->calls == 1); // Late workers never send to a disposed messenger.
  const std::vector<uint8_t> chunk(32768, 42);
  std::atomic<bool> running{true};
  Capture capture;
  auto handler = Listen(capture);
  for (size_t i = 0; i < 16; ++i) Check(handler->Send("data", "a", &chunk, &running));
  std::atomic<bool> done{false};
  std::thread worker([handler, &done, &running, &chunk]() {
    bool pressure = true;
    Check(handler->Send("data", "a", &chunk, &running, {}, &pressure));
    Check(!pressure);
    done.store(true);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  Check(!done.load());
  // A stalled UI recovers: every accepted byte reaches the sink exactly once.
  while (!done.load()) { Pump(); std::this_thread::yield(); }
  worker.join();
  PumpUntil([&capture]() { return capture.bytes == 17 * 32768; });
  Check(capture.connected == 1 && capture.bytes == 17 * 32768);
  Check(handler->Send("disconnected", "a", nullptr));
  PumpUntil([&capture]() { return capture.disconnected == 1; });
  Check(capture.disconnected == 1);
  handler->Shutdown();

  Capture overloaded;
  handler = Listen(overloaded);
  for (size_t i = 0; i < 16; ++i) Check(handler->Send("data", "a", &chunk, &running));
  worker = std::thread([handler, &chunk, &running]() {
    bool pressure = false;
    Check(!handler->Send("data", "a", &chunk, &running, {}, &pressure));
    Check(pressure);
    Check(handler->Send("disconnected", "a", nullptr, nullptr, "receive_queue_overflow"));
  });
  // No pumping until the worker reaches its one-second pressure deadline.
  worker.join();
  PumpUntil([&overloaded]() { return overloaded.disconnected == 1; });
  Check(overloaded.bytes == 0 && overloaded.disconnected == 1 &&
        overloaded.reason == "receive_queue_overflow");
  Check(handler->Send("connected", "a", nullptr));
  Check(handler->Send("data", "a", &chunk, &running));
  PumpUntil([&overloaded]() { return overloaded.bytes == 32768; });
  Check(overloaded.bytes == 32768); // Reconnect uses a fresh parser stream.
  handler->Shutdown();

  Capture stopped;
  handler = Listen(stopped);
  for (size_t i = 0; i < 16; ++i) Check(handler->Send("data", "a", &chunk, &running));
  worker = std::thread([handler, &chunk, &running]() {
    bool pressure = true;
    Check(!handler->Send("data", "a", &chunk, &running, {}, &pressure));
    Check(!pressure);
  });
  std::this_thread::sleep_for(std::chrono::milliseconds(30));
  const auto start = std::chrono::steady_clock::now();
  handler->Shutdown();
  handler.reset(); // Worker retains the object after UI resources are destroyed.
  worker.join();
  Check(std::chrono::steady_clock::now() - start < std::chrono::milliseconds(250));
  Pump();
  Check(stopped.bytes == 0 && stopped.connected == 0);
  std::cout << "Production Win32 handler: transient backpressure, overload "
               "disconnect, fresh reconnect, shutdown-during-wait and late-reply suppression passed\n";
}
