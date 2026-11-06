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
  HWND window_;
  bool automatic_ = false;
  bool beta_ = false;
  enum class Phase { idle, checking, available };
  Phase phase_ = Phase::idle;
  std::time_t next_check_ = 0;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
};
}  // namespace loongpass
