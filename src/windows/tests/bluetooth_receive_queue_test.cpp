#include "../runner/bluetooth_receive_queue.h"
#include <cstdlib>
#include <iostream>

void Check(bool condition) { if (!condition) std::abort(); }

int main() {
  BluetoothReceiveQueue q;
  Check(q.Begin("a"));
  Check(q.Begin("b"));
  std::vector<unsigned char> chunk(4096, 42);
  for (size_t i = 0; i < 128; ++i) Check(q.Push("a", chunk));
  Check(q.bytes() == q.kMaxBytes);
  // A million rejected pushes cannot increase storage or damage old bytes.
  for (size_t i = 0; i < 1000000; ++i) Check(!q.Push("b", chunk));
  Check(q.bytes() == q.kMaxBytes && q.size() <= q.kMaxDataEvents + 64);
  size_t bytes = 0;
  while (!q.empty()) {
    auto events = q.Drain();
    Check(events.size() <= 8);
    size_t turn = 0;
    for (const auto& event : events) {
      for (auto byte : event.data) Check(byte == 42);
      turn += event.data.size();
    }
    Check(turn <= 65536);
    bytes += turn;
  }
  Check(bytes == 524288 && q.bytes() == 0);

  // Separate addresses must not merge; the event bound protects tiny packets.
  for (size_t i = 0; i < 128; ++i)
    Check(q.Push(i % 2 ? "a" : "b", {static_cast<unsigned char>(i)}));
  Check(!q.Push("b", {128}));
  Check(q.data_events() == 128 && q.bytes() == 128);
  q.End("a", "receive_queue_overflow");
  Check(!q.IsOpen("a") && q.bytes() == 64);
  q.End("a");  // Duplicate close does not consume another terminal slot.
  size_t expected = 0, terminals = 0;
  while (!q.empty()) {
    for (const auto& event : q.Drain()) {
      if (event.type == "data") {
        Check(event.address == "b" && event.data == std::vector<unsigned char>{
            static_cast<unsigned char>(expected)});
        expected += 2;
      } else {
        Check(event.reason == "receive_queue_overflow");
        ++terminals;
      }
    }
  }
  Check(expected == 128 && terminals == 1 && q.Begin("a"));
  Check(!q.Push("a", std::vector<unsigned char>(32769)));
  q.Clear();

  // Reserve bounded terminal capacity even if the consumer never runs.
  for (size_t i = 0; i < q.kMaxConnections; ++i)
    Check(q.Begin(std::to_string(i)));
  Check(!q.Begin("excess"));
  for (size_t i = 0; i < q.kMaxConnections; ++i) q.End(std::to_string(i));
  Check(q.size() == 32 && q.bytes() == 0 && !q.Begin("excess"));
  q.Drain(32);
  Check(q.Begin("excess"));
  q.Clear();
  Check(q.empty() && q.bytes() == 0 && q.Begin("fresh"));
  std::cout << "Bounded receive queue: byte/event/connection limits, ordering, "
               "terminal reservation, reconnect and million-push stress passed\n";
}
