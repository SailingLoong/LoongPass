#pragma once

#include "codex_account_state.h"

#include <filesystem>
#include <functional>
#include <memory>

namespace loongpass::codex {
// Descriptor-checked access to the official authentication and audited local
// settings files. Configuration and conversation databases are outside this API.
class AuthFile {
 public:
  struct Snapshot {
    std::optional<std::string> data;
    std::string fingerprint;
    std::string digest() const { return data ? Digest(*data) : "absent"; }
    bool operator==(const Snapshot& other) const {
      return data == other.data && fingerprint == other.fingerprint;
    }
  };
  explicit AuthFile(const std::filesystem::path& root);
  ~AuthFile();
  AuthFile(const AuthFile&) = delete;
  AuthFile& operator=(const AuthFile&) = delete;
  Snapshot Read(const std::string& name = "auth.json") const;
  void Replace(const std::string& data, const Snapshot& expected,
      const std::string& stage, const std::string& name,
      const std::function<void()>& ensureStopped) const;
  void DiscardStage(const std::string& name, const std::string& digest) const;
  void WithExclusive(const std::function<void()>& action) const;
  std::string RootRevision() const;
  const std::filesystem::path& root() const;

 private:
  struct State;
  std::unique_ptr<State> state_;
};
}  // namespace loongpass::codex
