#pragma once

#include <nlohmann/json.hpp>

#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace loongpass::codex {
using Json = nlohmann::json;

enum class FailureCode {
  unavailable, invalidCredential, accountNotFound, unsafePath, busy,
  sourceChanged, recoveryConflict, settingsUnavailable, unsupportedStore,
  restricted, timeout, cancelled, loginRequired, protocolError
};

class Failure : public std::runtime_error {
 public:
  explicit Failure(FailureCode value)
      : std::runtime_error("Codex operation unavailable"), code(value) {}
  const FailureCode code;
};

std::string Digest(const std::string& data);
std::string EncodeBase64(const std::string& data);
std::string DecodeBase64(const std::string& data);

// A local identity projection. Only the official executable validates/renews a
// grant. Keep its complete original document, including unknown future fields.
struct Credential {
  explicit Credential(std::string bytes);
  Json Summary(bool current) const;
  std::string data, id, email, workspaceId, userId, plan, rendererOwnerKey;
};

class AuthPolicy {
 public:
  explicit AuthPolicy(const Json& configuration);
  void Validate(const std::string& workspace) const;
  std::vector<std::string> LoginOverrides() const;

 private:
  std::optional<std::string> workspace_;
};

struct LocalSettings {
  static constexpr size_t maximumBytes = 3 * 1024 * 1024;
  static constexpr const char* fileName = ".codex-global-state.json";
  static constexpr const char* databaseFileName = ".codex-global-state.sqlite";
  static std::optional<std::string> ActiveOwner(const std::string& data);
  static std::string Transfer(const std::string& data,
      const std::optional<Credential>& source, const Credential& target);
};
}  // namespace loongpass::codex
