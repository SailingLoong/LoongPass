#pragma once
#include "native_support.h"
#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>
#include <memory>
#include <ctime>

namespace loongpass {
class NativeUpdater {
 public:
  NativeUpdater(HWND window, flutter::BinaryMessenger* messenger);
  ~NativeUpdater();
  bool HandleMessage(UINT message, WPARAM parameter);

 private:
  Json State() const;
  void Publish();
  void Check(bool automatic);
  bool OwnsCandidate() const;
  HWND window_;
  bool automatic_ = false, beta_ = false;
  std::string phase_, offered_version_, error_;
  Json progress_ = nullptr;
  int64_t revision_ = 0;
  std::time_t next_check_ = 0;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
};
}  // namespace loongpass
