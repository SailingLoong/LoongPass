#pragma once

#include "codex_auth_file.h"
#include "native_storage.h"

#include <map>

namespace loongpass::codex {
// One native writer owns saved grants. No raw document leaves this adapter.
class AccountStore {
 public:
  explicit AccountStore(const std::filesystem::path& root);
  std::string Capture(const std::string& data);
  Credential Saved(const std::string& id) const;
  void Remove(const std::string& id);
  void Observe(const std::optional<std::string>& data);
  Json Summaries(const std::optional<std::string>& current) const;
  void Activate(const std::string& id, AuthFile& auth,
                const std::function<void()>& ensureStopped);
  const std::filesystem::path& root() const { return file_.root(); }

 private:
  void Save(const std::map<std::string, Credential>& accounts);
  void Recover(AuthFile& auth, const std::function<void()>& ensureStopped);
  NativeAccountFile file_;
  std::map<std::string, Credential> saved_;
};
}  // namespace loongpass::codex
