#pragma once
#include "codex_app_server.h"
#include "codex_auth_file.h"

namespace loongpass::codex {
AuthPolicy ReadPolicy(const std::filesystem::path& executable,
                      const std::filesystem::path& home, const Cancelled& cancelled);
Credential RenewLogin(const std::filesystem::path& executable, AuthFile& scratch,
                      const Credential& previous, const AuthPolicy& policy,
                      const Cancelled& cancelled,
                      const std::function<void(const Credential&)>& preserve);
}  // namespace loongpass::codex
