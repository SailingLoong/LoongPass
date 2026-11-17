#pragma once
#include "codex_process.h"
#include <map>

namespace loongpass::codex {
class AppServer {
 public:
  AppServer(const std::filesystem::path& executable, const std::filesystem::path& home,
            const std::vector<std::string>& overrides = {}, Cancelled cancelled = {},
            std::chrono::milliseconds timeout = std::chrono::seconds(20));
  Json Request(const std::string& method, const Json& params = Json::object());
  bool WaitForLogin(const std::string& id);
  void Close() { child_.Close(); }

 private:
  Json Receive(Deadline deadline);
  void Notification(const Json& object);
  StdioProcess child_;
  Cancelled cancelled_;
  std::chrono::milliseconds timeout_;
  std::string buffer_;
  int64_t nextId_ = 0;
  std::map<std::string, bool> logins_;
};
}  // namespace loongpass::codex
