#pragma once

#include "native_support.h"

#include <memory>

namespace loongpass {

class NativeAuthorization {
 public:
  explicit NativeAuthorization(HWND parent);
  ~NativeAuthorization();
  bool Handle(const Call& call, std::unique_ptr<Result>& result);

 private:
  struct State;
  std::unique_ptr<State> state_;
};

}  // namespace loongpass
