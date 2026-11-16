#include "codex_auth_session.h"
#include "native_support.h"

namespace loongpass::codex {
AuthPolicy ReadPolicy(const std::filesystem::path& executable,
    const std::filesystem::path& home, const Cancelled& cancelled) {
  AppServer server(executable, home, {}, cancelled);
  const auto reply = server.Request("config/read", {{"includeLayers", false}});
  if (!reply.value("config", Json()).is_object()) throw Failure(FailureCode::protocolError);
  AuthPolicy policy(reply.at("config"));
  server.Close();
  return policy;
}
Credential RenewLogin(const std::filesystem::path& executable, AuthFile& scratch,
    const Credential& previous, const AuthPolicy& policy, const Cancelled& cancelled,
    const std::function<void(const Credential&)>& preserve) {
  scratch.Replace(previous.data, scratch.Read(), ".loongpass-codex-auth-" + RandomHex(16),
      "auth.json", [] {});
  std::exception_ptr failure;
  std::unique_ptr<AppServer> server;
  try {
    server = std::make_unique<AppServer>(executable, scratch.root(), policy.LoginOverrides(), cancelled);
    const auto reply = server->Request("account/read", {{"refreshToken", true}});
    const auto account = reply.value("account", Json());
    if (!account.is_object() || account.value("type", Json()) != "chatgpt")
      throw Failure(FailureCode::loginRequired);
  } catch (...) { failure = std::current_exception(); }
  if (server) server->Close();
  // Refresh may have succeeded even when its response was lost or the caller
  // cancelled. Preserve the same identity's final grant before propagating it.
  const auto final = scratch.Read();
  if (!final.data) throw Failure(FailureCode::loginRequired);
  Credential credential(*final.data);
  if (credential.id != previous.id) throw Failure(FailureCode::loginRequired);
  policy.Validate(credential.workspaceId);
  preserve(credential);
  if (failure) std::rethrow_exception(failure);
  if (cancelled && cancelled()) throw Failure(FailureCode::cancelled);
  return credential;
}
}  // namespace loongpass::codex
