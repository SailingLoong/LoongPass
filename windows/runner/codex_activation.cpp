#include "codex_activation.h"

namespace loongpass::codex {
std::string RunActivation(const std::string& workspace,
    const std::function<void(bool&)>& quit,
    const std::function<AuthPolicy()>& policy, const std::function<void()>& apply,
    const std::function<bool()>& reopen) {
  bool wasRunning = false;
  try {
    quit(wasRunning);
    policy().Validate(workspace);
    apply();
  } catch (...) {
    if (wasRunning) reopen();
    throw;
  }
  return reopen() ? "opened" : "applied";
}
}  // namespace loongpass::codex
