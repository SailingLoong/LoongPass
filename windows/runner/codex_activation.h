#pragma once
#include "codex_account_state.h"
#include <functional>

namespace loongpass::codex {
// OS operations are injected so checks cannot stop a real desktop.
std::string RunActivation(const std::string& workspace,
    const std::function<void(bool&)>& quit,
    const std::function<AuthPolicy()>& policy, const std::function<void()>& apply,
    const std::function<bool()>& reopen);
}  // namespace loongpass::codex
