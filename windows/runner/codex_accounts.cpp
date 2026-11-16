#include "codex_accounts.h"
#include "codex_account_store.h"
#include "codex_activation.h"
#include "codex_auth_session.h"
#include "codex_desktop_client.h"

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <set>
#include <thread>

namespace loongpass::codex {
namespace {
constexpr UINT kCompletion = WM_APP + 232;
struct ScratchHome {
  std::filesystem::path root;
  std::unique_ptr<NativeAccountFile> owner;
  std::unique_ptr<AuthFile> auth;
  bool retain = false;
  explicit ScratchHome(const std::filesystem::path& parent)
      : root(parent / Wide("authorization-" + RandomHex(16))),
        owner(std::make_unique<NativeAccountFile>(root)), auth(std::make_unique<AuthFile>(root)) {}
  ~ScratchHome() {
    auth.reset(); owner.reset();
    if (retain) return;  // A failed durable save must not delete the only fresh grant.
    std::error_code error;
    std::filesystem::remove_all(root, error);
  }
};
std::string Timestamp() {
  SYSTEMTIME time = {}; GetSystemTime(&time);
  char buffer[32] = {};
  sprintf_s(buffer, "%04u-%02u-%02uT%02u:%02u:%02uZ", time.wYear, time.wMonth,
      time.wDay, time.wHour, time.wMinute, time.wSecond);
  return buffer;
}
}  // namespace
struct Accounts::State {
  struct Command { std::string method, id; std::unique_ptr<Result> result; };
  struct Completion { std::unique_ptr<Result> result; Json snapshot; };
  explicit State(HWND target) : window(target), worker([this] { Run(); }) {}
  ~State() {
    stopping = true; cancelLogin = true; wake.notify_all();
    worker.join();
    Drain();
  }
  HWND window;
  std::mutex mutex;
  std::condition_variable wake;
  Json snapshot = {{"available", false}, {"issue", "unavailable"}, {"accounts", Json::array()},
                   {"busy", true}, {"loginPending", false}, {"quitMode", "force"}};
  std::deque<Command> commands;
  std::deque<Completion> completed;
  std::atomic<bool> stopping{false}, cancelLogin{false};
  std::unique_ptr<AccountStore> accounts;
  std::unique_ptr<AuthFile> auth;
  std::optional<std::string> current;
  std::optional<AuthFile::Snapshot> observed;
  std::thread worker;  // Start after all state has been initialized.

  Cancelled Cancellation(bool login = false) {
    return [this, login] { return stopping.load() || (login && cancelLogin.load()); };
  }
  Json Snapshot() { std::lock_guard<std::mutex> guard(mutex); return snapshot; }
  void Update(const Json& patch) {
    std::lock_guard<std::mutex> guard(mutex);
    snapshot.update(patch);
  }
  void PublishAccounts() {
    Update({{"accounts", accounts ? accounts->Summaries(current) : Json::array()},
        {"currentId", current ? Json(*current) : Json()}});
  }
  void Observe(bool force = false) {
    if (!auth || !accounts) return;
    const auto next = auth->Read();
    if (!force && observed && *observed == next) return;
    current.reset();
    if (next.data) {
      try { current = Credential(*next.data).id; accounts->Observe(next.data); }
      catch (const Failure& error) { if (error.code != FailureCode::invalidCredential) throw; }
    }
    observed = next;
    PublishAccounts();
    Update({{"observedAt", Timestamp()}});
  }
  void Report(FailureCode code, bool initialize = false) {
    Json patch = {{"outcome", nullptr}};
    if (initialize) patch["available"] = false;
    switch (code) {
      case FailureCode::unsupportedStore:
        patch.update({{"available", false}, {"issue", "unsupportedStore"},
          {"message", "当前 Codex 使用的凭据存储暂不支持，Pass 没有修改它的设置。"}}); break;
      case FailureCode::restricted:
        patch.update({{"issue", "restricted"}, {"message", "此账号不符合 Codex 的登录方式或工作区限制，登录保持原样。"}}); break;
      case FailureCode::loginRequired:
      case FailureCode::invalidCredential:
        patch["message"] = "Codex 授权需要更新，请重新通过官方窗口授权。"; break;
      case FailureCode::busy:
        patch["message"] = "请先结束其他 Codex 命令行任务，并确认桌面客户端可以退出后重试。"; break;
      case FailureCode::cancelled:
        patch["message"] = "已取消本次 Codex 操作，当前登录保持原样。"; break;
      case FailureCode::timeout:
        patch["message"] = "Codex 操作超时，请稍后重试。"; break;
      case FailureCode::settingsUnavailable:
        patch["message"] = "无法安全确认 Codex 的本机设置，未切换账号。请保留现有数据并核对客户端版本与当前登录。"; break;
      case FailureCode::recoveryConflict:
        patch["message"] = "上次切换的登录或本机设置存在冲突，已保留恢复记录；请先核对现有数据。"; break;
      case FailureCode::sourceChanged:
        patch["message"] = "检测到其他程序修改了 Codex 登录或设置，请核对现有登录后重试。"; break;
      default:
        if (initialize) patch["issue"] = "runtimeUnavailable";
        patch["message"] = "未能完成 Codex 账号操作，请核对官方客户端、文件访问和其他运行中的任务后重试。"; break;
    }
    Update(patch);
  }
  void Initialize() {
    accounts = std::make_unique<AccountStore>(ApplicationDataRoot() / L"Codex");
    auth = std::make_unique<AuthFile>(CodexHome());
    const auto client = DesktopClient::Installed(Cancellation());
    ReadPolicy(client.executable, auth->root(), Cancellation());
    Observe(true);
    Update({{"available", true}, {"issue", ""}});
  }
  void Authorize() {
    const auto cancelled = Cancellation(true);
    const auto client = DesktopClient::Installed(cancelled);
    const auto policy = ReadPolicy(client.executable, auth->root(), cancelled);
    ScratchHome scratch(accounts->root());
    AppServer server(client.executable, scratch.root, policy.LoginOverrides(), cancelled);
    const auto login = server.Request("account/login/start", {{"type", "chatgpt"}});
    if (!login.value("loginId", Json()).is_string() || !login.value("authUrl", Json()).is_string())
      throw Failure(FailureCode::protocolError);
    if (cancelled()) throw Failure(FailureCode::cancelled);
    OpenOfficialAuthorization(login.at("authUrl"));
    Update({{"message", "请在浏览器中完成 Codex 官方授权；完成后会保存账号。"}});
    if (!server.WaitForLogin(login.at("loginId"))) throw Failure(FailureCode::loginRequired);
    server.Close();
    if (cancelled()) throw Failure(FailureCode::cancelled);
    const auto final = scratch.auth->Read();
    if (!final.data) throw Failure(FailureCode::loginRequired);
    const Credential credential(*final.data);
    policy.Validate(credential.workspaceId);
    accounts->Capture(credential.data);
    Update({{"message", "已保存官方账号。点击切换后应用到 Codex，原项目和对话设置继续保留。"}});
  }
  void Activate(const std::string& id) {
    const auto cancelled = Cancellation();
    const auto client = DesktopClient::Installed(cancelled);
    auto policy = ReadPolicy(client.executable, auth->root(), cancelled);
    Observe(true);
    const auto target = accounts->Saved(id);
    policy.Validate(target.workspaceId);
    if (current != id) {
      ScratchHome scratch(accounts->root());
      scratch.retain = true;
      RenewLogin(client.executable, *scratch.auth, target, policy, cancelled, [&](const Credential& fresh) {
        accounts->Capture(fresh.data);
        scratch.retain = false;
      });
    }
    const auto outcome = RunActivation(target.workspaceId, [&](bool& wasRunning) {
      client.Quit(cancelled, wasRunning);
    }, [&] {
      const auto installed = DesktopClient::Installed(cancelled);
      if (!client.SameInstallation(installed)) throw Failure(FailureCode::sourceChanged);
      return ReadPolicy(client.executable, auth->root(), cancelled);
    }, [&] {
      accounts->Activate(id, *auth, [&] { client.EnsureStopped(cancelled); });
    }, [&] { return client.Reopen(); });
    Update({{"outcome", outcome}, {"message", outcome == "opened" ?
      "已应用账号登录并重开 Codex，请核对客户端账号。项目和对话设置保留。" :
      "已应用账号登录，请打开 Codex 并核对账号。项目和对话设置保留。"}});
  }
  void Execute(const Command& command) {
    Update({{"outcome", nullptr}, {"message", nullptr}, {"issue", ""}});
    if (command.method == "codexStartLogin") Authorize();
    else if (command.method == "codexActivate") Activate(command.id);
    else if (command.method == "codexRemove") {
      accounts->Remove(command.id);
      Update({{"message", "已从 Pass 移除保存的账号，Codex 当前登录保持原样。"}});
    } else if (command.method == "codexImportCurrent") {
      const auto client = DesktopClient::Installed(Cancellation());
      const auto policy = ReadPolicy(client.executable, auth->root(), Cancellation());
      const auto live = auth->Read();
      if (!live.data) throw Failure(FailureCode::loginRequired);
      const Credential value(*live.data);
      policy.Validate(value.workspaceId);
      accounts->Capture(value.data);
      Update({{"message", "已保存本机 Codex 登录，项目和对话设置保持原样。"}});
    }
  }
  void Run() {
    try { Initialize(); }
    catch (const Failure& error) { Report(error.code, true); }
    catch (...) { Report(FailureCode::unavailable, true); }
    Update({{"busy", false}});
    while (!stopping) {
      Command command;
      {
        std::unique_lock<std::mutex> guard(mutex);
        wake.wait_for(guard, std::chrono::seconds(2), [&] { return stopping || !commands.empty(); });
        if (stopping) break;
        if (!commands.empty()) { command = std::move(commands.front()); commands.pop_front(); }
      }
      if (!command.method.empty() && command.method != "codexCancelLogin") {
        try { Execute(command); }
        catch (const Failure& error) { Report(error.code); }
        catch (...) { Report(FailureCode::unavailable); }
        Update({{"busy", false}, {"loginPending", false}});
      }
      if (accounts && auth && Snapshot().value("available", false)) {
        try { Observe(); PublishAccounts(); }
        catch (const Failure& error) { Report(error.code); }
        catch (...) { Report(FailureCode::unavailable); }
      }
      if (command.result) {
        std::lock_guard<std::mutex> guard(mutex);
        completed.push_back({std::move(command.result), snapshot});
        PostMessageW(window, kCompletion, 0, 0);
      }
    }
    // Destroy pinned private/auth directories on their owning worker.
    auth.reset(); accounts.reset();
  }
  void Drain() {
    std::deque<Completion> ready;
    { std::lock_guard<std::mutex> guard(mutex); ready.swap(completed); }
    for (auto& item : ready) item.result->Success(Encode(item.snapshot));
  }
};

Accounts::Accounts(HWND window) : state_(std::make_unique<State>(window)) {}
Accounts::~Accounts() = default;
bool Accounts::HandleMessage(UINT message) {
  if (message != kCompletion) return false;
  state_->Drain(); return true;
}
bool Accounts::Handle(const Call& call, std::unique_ptr<Result>& result) {
  static const std::set<std::string> methods = {"codexAccountsStatus", "codexImportCurrent", "codexStartLogin",
      "codexCancelLogin", "codexActivate", "codexRemove"};
  const auto& method = call.method_name();
  if (!methods.count(method)) return false;
  if (method == "codexAccountsStatus") { result->Success(Encode(state_->Snapshot())); return true; }
  Json args;
  try { args = Decode(call.arguments()); }
  catch (...) { result->Error("codex_invalid_arguments"); return true; }
  if (args.is_null()) args = Json::object();
  const bool selection = method == "codexActivate" || method == "codexRemove";
  if (!args.is_object() || (selection ? (args.size() != 1 || !args.value("id", Json()).is_string() ||
      args.at("id").get<std::string>().empty() || args.at("id").get<std::string>().size() > 128) : !args.empty())) {
    result->Error("codex_invalid_arguments"); return true;
  }
  std::unique_lock<std::mutex> guard(state_->mutex);
  if (method == "codexCancelLogin") state_->cancelLogin = true;
  else {
    if (!state_->snapshot.value("available", false) || state_->snapshot.value("busy", true) ||
        state_->snapshot.value("loginPending", false) || state_->stopping) {
      const auto copy = state_->snapshot; guard.unlock(); result->Success(Encode(copy)); return true;
    }
    const bool login = method == "codexStartLogin";
    state_->snapshot["busy"] = !login;
    state_->snapshot["loginPending"] = login;
    state_->snapshot["outcome"] = nullptr;
    if (login) { state_->cancelLogin = false; state_->snapshot["message"] = "正在打开 Codex 官方授权。"; }
  }
  State::Command command{method, selection ? args.at("id").get<std::string>() : "", nullptr};
  if (method == "codexStartLogin") {
    const auto copy = state_->snapshot;
    state_->commands.push_back(std::move(command));
    guard.unlock(); state_->wake.notify_one(); result->Success(Encode(copy));
  } else {
    command.result = std::move(result);
    state_->commands.push_back(std::move(command));
    guard.unlock(); state_->wake.notify_one();
  }
  return true;
}
}  // namespace loongpass::codex
