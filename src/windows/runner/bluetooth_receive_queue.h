// Copyright 2026 HTCommander contributors - Apache 2.0
#pragma once

#include <cstddef>
#include <deque>
#include <map>
#include <string>
#include <utility>
#include <vector>

// Caller provides synchronization. Connection slots reserve room for terminal
// events, so overload can always report a disconnect without blocking the UI.
class BluetoothReceiveQueue {
 public:
  struct Event {
    std::string type;
    std::string address;
    std::vector<unsigned char> data;
    std::string reason;
  };
  static constexpr size_t kMaxConnections = 32;
  static constexpr size_t kMaxDataEvents = 128;
  static constexpr size_t kMaxBytes = 512 * 1024;
  static constexpr size_t kMaxChunk = 32768;

  bool Begin(const std::string& address) {
    if (connections_.count(address) ||
        connections_.size() >= kMaxConnections) return false;
    connections_[address] = false;
    events_.push_back({"connected", address, {}, {}});
    return true;
  }

  bool IsOpen(const std::string& address) const {
    auto it = connections_.find(address);
    return it != connections_.end() && !it->second;
  }

  bool CanPush(const std::string& address, size_t size) const {
    if (!IsOpen(address) || size > kMaxChunk ||
        size > kMaxBytes - bytes_) return false;
    return CanMerge(address, size) || data_events_ < kMaxDataEvents;
  }

  bool Push(const std::string& address,
            const std::vector<unsigned char>& data) {
    if (!CanPush(address, data.size())) return false;
    if (CanMerge(address, data.size())) {
      auto& previous = events_.back().data;
      previous.insert(previous.end(), data.begin(), data.end());
    } else {
      events_.push_back({"data", address, data, {}});
      ++data_events_;
    }
    bytes_ += data.size();
    return true;
  }

  void End(const std::string& address, const std::string& reason = {}) {
    auto connection = connections_.find(address);
    if (connection == connections_.end() || connection->second) return;
    connection->second = true;
    // Never deliver a partial old stream after its connection was stopped.
    // Other radios remain in order. This also releases all of its byte budget.
    for (auto it = events_.begin(); it != events_.end();) {
      if (it->address == address) {
        if (it->type == "data") {
          bytes_ -= it->data.size();
          --data_events_;
        }
        it = events_.erase(it);
      } else {
        ++it;
      }
    }
    events_.push_back({"disconnected", address, {}, reason});
  }

  std::vector<Event> Drain(size_t max_events = 8,
                           size_t max_bytes = 64 * 1024) {
    std::vector<Event> result;
    size_t drained_bytes = 0;
    while (!events_.empty() && result.size() < max_events) {
      auto& next = events_.front();
      if (!result.empty() && drained_bytes + next.data.size() > max_bytes) break;
      if (next.type == "data") {
        bytes_ -= next.data.size();
        drained_bytes += next.data.size();
        --data_events_;
      } else if (next.type == "disconnected") {
        connections_.erase(next.address);
      }
      result.push_back(std::move(next));
      events_.pop_front();
    }
    return result;
  }

  void Clear() {
    events_.clear();
    connections_.clear();
    bytes_ = 0;
    data_events_ = 0;
  }
  bool empty() const { return events_.empty(); }
  size_t bytes() const { return bytes_; }
  size_t size() const { return events_.size(); }
  size_t data_events() const { return data_events_; }

 private:
  bool CanMerge(const std::string& address, size_t size) const {
    return !events_.empty() && events_.back().type == "data" &&
           events_.back().address == address &&
           events_.back().data.size() + size <= kMaxChunk;
  }
  std::deque<Event> events_;
  std::map<std::string, bool> connections_;
  size_t bytes_ = 0;
  size_t data_events_ = 0;
};
