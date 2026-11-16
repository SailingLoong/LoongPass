#pragma once
#include "native_support.h"
#include <memory>

namespace loongpass::codex {
// App-lifetime native owner. Channel status calls copy an existing snapshot;
// the worker owns initialization, observations, authorization and mutations.
class Accounts {
 public:
  explicit Accounts(HWND window);
  ~Accounts();
  bool Handle(const Call& call, std::unique_ptr<Result>& result);
  bool HandleMessage(UINT message);

 private:
  struct State;
  std::unique_ptr<State> state_;
};
}  // namespace loongpass::codex
