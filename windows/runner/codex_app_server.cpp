#include "codex_app_server.h"
#include "native_support.h"

namespace loongpass::codex {
namespace {
std::vector<std::wstring> Arguments(const std::vector<std::string>& overrides) {
  std::vector<std::wstring> output;
  for (const auto& item : overrides) { output.push_back(L"-c"); output.push_back(Wide(item)); }
  output.push_back(L"app-server");
  return output;
}
}  // namespace
AppServer::AppServer(const std::filesystem::path& executable, const std::filesystem::path& home,
    const std::vector<std::string>& overrides, Cancelled cancelled, std::chrono::milliseconds timeout)
    : child_(executable, Arguments(overrides), home), cancelled_(std::move(cancelled)), timeout_(timeout) {
  Request("initialize", {{"clientInfo", {{"name", "loongpass"}, {"version", "1.0.0"}}},
                          {"capabilities", Json::object()}});
  child_.Write(Json({{"method", "initialized"}}).dump() + "\n");
}
Json AppServer::Receive(Deadline deadline) {
  while (true) {
    if (cancelled_ && cancelled_()) throw Failure(FailureCode::cancelled);
    if (std::chrono::steady_clock::now() >= deadline) throw Failure(FailureCode::timeout);
    const auto end = buffer_.find('\n');
    if (end != std::string::npos) {
      auto line = buffer_.substr(0, end);
      buffer_.erase(0, end + 1);
      if (line.empty() || line == "\r") continue;
      auto value = Json::parse(line, nullptr, false);
      if (!value.is_object()) throw Failure(FailureCode::protocolError);
      return value;
    }
    const auto part = child_.Read(deadline, cancelled_);
    if (part.empty()) throw Failure(FailureCode::unavailable);
    buffer_ += part;
    if (buffer_.size() > 4 * 1024 * 1024) throw Failure(FailureCode::protocolError);
  }
}
void AppServer::Notification(const Json& object) {
  if (object.value("method", Json()) != "account/login/completed") return;
  const auto params = object.value("params", Json());
  if (!params.is_object() || !params.value("success", Json()).is_boolean())
    throw Failure(FailureCode::protocolError);
  const auto id = params.value("loginId", Json());
  // The official protocol permits unscoped completions. They cannot resolve a
  // browser login or interrupt an unrelated account/read response.
  if (id.is_null()) return;
  if (!id.is_string()) throw Failure(FailureCode::protocolError);
  if (logins_.size() < 8) logins_[id.get<std::string>()] = params.at("success").get<bool>();
}
Json AppServer::Request(const std::string& method, const Json& params) {
  if (cancelled_ && cancelled_()) throw Failure(FailureCode::cancelled);
  const auto id = ++nextId_;
  child_.Write(Json({{"id", id}, {"method", method}, {"params", params}}).dump() + "\n");
  const auto deadline = std::chrono::steady_clock::now() + timeout_;
  while (true) {
    const auto reply = Receive(deadline);
    if (reply.value("id", Json()) == id) {
      if (!reply.value("result", Json()).is_object()) throw Failure(FailureCode::protocolError);
      return reply.at("result");
    }
    Notification(reply);
  }
}
bool AppServer::WaitForLogin(const std::string& id) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::minutes(5);
  while (true) {
    const auto found = logins_.find(id);
    if (found != logins_.end()) { const auto result = found->second; logins_.erase(found); return result; }
    Notification(Receive(deadline));
  }
}
}  // namespace loongpass::codex
