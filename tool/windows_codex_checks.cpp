// Synthetic native checks. No installed client is stopped or authenticated.
#include "../windows/runner/codex_account_state.h"
#include "../windows/runner/codex_account_store.h"
#include "../windows/runner/codex_auth_session.h"
#include "../windows/runner/codex_activation.h"
#include "../windows/runner/codex_desktop_client.h"

#include <fstream>
#include <iostream>
#include <map>
#include <stdexcept>
#include <windows.h>
#include <aclapi.h>
#include <atomic>
#include <thread>

namespace {
using namespace loongpass::codex;
struct TemporaryDirectory {
  std::filesystem::path path;
  TemporaryDirectory() {
    wchar_t buffer[MAX_PATH + 1] = {};
    const auto count = GetTempPathW(MAX_PATH, buffer);
    if (!count || count >= MAX_PATH) throw std::runtime_error("Temporary root unavailable");
    path = std::filesystem::path(buffer) / loongpass::Wide("loongpass-codex-check-" + loongpass::RandomHex(16));
    std::filesystem::create_directory(path);
  }
  ~TemporaryDirectory() { std::error_code error; std::filesystem::remove_all(path, error); }
};
std::string Read(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  return std::string(std::istreambuf_iterator<char>(input), std::istreambuf_iterator<char>());
}
void Write(const std::filesystem::path& path, const std::string& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output << bytes;
  if (!output) throw std::runtime_error("Fixture write failed");
}
}  // namespace

namespace {
int ControlledChild() {
  const auto mode = Json::parse(Read(std::filesystem::current_path() / L"fixture-mode.json"));
  const auto behavior = mode.value("behavior", "normal");
  if (behavior == "eof") return 0;
  auto send = [](const Json& value) { std::cout << value.dump() << '\n' << std::flush; };
  std::string line;
  while (std::getline(std::cin, line)) {
    const auto request = Json::parse(line);
    if (!request.contains("id")) continue;
    if (request.at("method") != "initialize") {
      if (behavior == "hang") { Sleep(10000); return 0; }
      if (behavior == "malformed") { std::cout << "not JSON\n" << std::flush; continue; }
      if (behavior == "oversized") { std::cout << std::string(4 * 1024 * 1024 + 1, 'x') << std::flush; continue; }
    }
    send({{"id", 999999}, {"result", {{"unrelated", true}}}});
    send({{"method", "account/login/completed"}, {"params", {{"loginId", "synthetic-login"}, {"success", true}}}});
    Json reply = {{"correlated", true}, {"pid", GetCurrentProcessId()}};
    if (request.at("method") == "account/read" && behavior == "lost-response") break;
    if (request.at("method") == "account/read") reply["account"] = {{"type", "chatgpt"}};
    send({{"id", request.at("id")}, {"result", reply}});
  }
  if (mode.contains("final")) Write(std::filesystem::current_path() / L"auth.json", mode.at("final"));
  if (mode.value("cancelOnClose", false)) Write(std::filesystem::current_path() / L"shutdown-complete", "done");
  return 0;
}

void Check(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <typename Action>
void Refuses(loongpass::codex::FailureCode code, Action action) {
  try { action(); }
  catch (const loongpass::codex::Failure& error) {
    Check(error.code == code, "Wrong native failure classification");
    return;
  }
  throw std::runtime_error("Unsafe operation was accepted");
}

void RuntimeChecks(const std::map<std::string, Credential>& values) {
  TemporaryDirectory temporary;
  wchar_t path[32768] = {};
  Check(GetModuleFileNameW(nullptr, path, 32768) != 0, "Controlled executable unavailable");
  auto scenario = [&](const char* name, const char* behavior) {
    const auto root = temporary.path / loongpass::Wide(name);
    std::filesystem::create_directory(root);
    Write(root / L"fixture-mode.json", Json({{"behavior", behavior}}).dump());
    return root;
  };
  {
    const auto root = scenario("normal", "normal");
    AppServer server(path, root);
    const auto reply = server.Request("test/correlation");
    Check(reply.at("correlated") == true && !reply.contains("unrelated"), "Unrelated RPC response was accepted");
    Check(server.WaitForLogin("synthetic-login"), "Early login notification was lost");
    const auto process = OpenProcess(SYNCHRONIZE, FALSE, reply.at("pid").get<DWORD>());
    Check(process != nullptr, "Controlled process handle unavailable");
    server.Close(); server.Close();
    Check(WaitForSingleObject(process, 0) == WAIT_OBJECT_0, "Close did not reap the owned child");
    CloseHandle(process);
  }
  Refuses(FailureCode::unavailable, [&] { AppServer server(path, scenario("eof", "eof")); });
  Refuses(FailureCode::protocolError, [&] {
    AppServer server(path, scenario("malformed", "malformed")); server.Request("test/malformed");
  });
  Refuses(FailureCode::protocolError, [&] {
    AppServer server(path, scenario("oversized", "oversized")); server.Request("test/oversized");
  });
  Refuses(FailureCode::timeout, [&] {
    AppServer server(path, scenario("timeout", "hang"), {}, {}, std::chrono::milliseconds(200));
    server.Request("test/timeout");
  });
  {
    std::atomic<bool> cancelled{false};
    AppServer server(path, scenario("cancel", "hang"), {}, [&] { return cancelled.load(); });
    std::thread cancel([&] { Sleep(50); cancelled = true; });
    Refuses(FailureCode::cancelled, [&] { server.Request("test/cancel"); });
    cancel.join(); server.Close();
  }
  {
    const auto root = temporary.path / L"renew";
    loongpass::NativeAccountFile owner(root);
    AuthFile auth(root);
    Write(root / L"fixture-mode.json", Json({{"final", values.at("b-rotated").data}}).dump());
    const AuthPolicy policy({{"cli_auth_credentials_store", "file"}});
    const auto fresh = RenewLogin(path, auth, values.at("b"), policy, {}, [](const Credential&) {});
    Check(fresh.data == values.at("b-rotated").data,
          "Renewal saved the pre-shutdown grant instead of the child's final write");
  }
  for (const auto* behavior : {"cancel", "lost-response"}) {
    const auto root = temporary.path / loongpass::Wide(std::string("renew-") + behavior);
    loongpass::NativeAccountFile owner(root);
    AuthFile auth(root);
    AccountStore saved(temporary.path / loongpass::Wide(std::string("saved-") + behavior));
    saved.Capture(values.at("b").data);
    Write(root / L"fixture-mode.json", Json({{"final", values.at("b-rotated").data},
        {"behavior", behavior}, {"cancelOnClose", std::string(behavior) == "cancel"}}).dump());
    const auto cancelled = [&] { return std::filesystem::exists(root / L"shutdown-complete"); };
    Refuses(std::string(behavior) == "cancel" ? FailureCode::cancelled : FailureCode::unavailable, [&] {
      const auto fresh = RenewLogin(path, auth, values.at("b"),
          AuthPolicy({{"cli_auth_credentials_store", "file"}}), cancelled,
          [&](const Credential& value) { saved.Capture(value.data); });
      Check(fresh.id == values.at("b").id, "Renewal changed identity");
    });
    Check(saved.Saved(values.at("b").id).data == values.at("b-rotated").data,
          "Interrupted refresh discarded the child's final rotated grant");
  }
  std::cout << "Codex runtime checks passed: correlation, login notification, EOF, malformed/oversized frames, timeout, cancellation, reaping, final grant\n";
}


void TransactionChecks(const Json& fixture, const std::map<std::string, Credential>& values) {
  TemporaryDirectory temporary;
  const auto home = temporary.path / L"home";
  const auto privateRoot = temporary.path / L"accounts";
  const auto& a = values.at("a");
  const auto& b = values.at("b");
  const auto& rotated = values.at("b-rotated");
  const auto settings = fixture.at("settings").front().at("document").dump();
  const auto expected = fixture.at("settings").front().at("expected");
  const auto unchangedConfig = std::string("model_provider = \"custom\"\n# preserve these exact bytes\n");
  {
    AccountStore store(privateRoot);
    store.Capture(a.data);
    store.Capture(b.data);
    AuthFile auth(home);
    auth.Replace(a.data, auth.Read(), ".loongpass-codex-auth-" + std::string(32, 'a'), "auth.json", [] {});
    auth.Replace(settings, auth.Read(LocalSettings::fileName),
        ".loongpass-codex-settings-" + std::string(32, 'b'), LocalSettings::fileName, [] {});
    Write(home / L"config.toml", unchangedConfig);
    Write(home / L"conversation-fixture.sqlite", "conversation bytes");
    store.Activate(b.id, auth, [] {});
    Check(auth.Read().data == b.data, "A to B did not apply the selected grant");
    Check(Json::parse(*auth.Read(LocalSettings::fileName).data) == expected,
          "Native transaction did not seed audited target preferences");
    Write(home / L"auth.json", rotated.data);
    store.Activate(a.id, auth, [] {});
    Check(auth.Read().data == a.data, "B to A did not restore A");
    Check(store.Saved(b.id).data == rotated.data, "Latest outgoing refresh grant was lost");
    store.Activate(b.id, auth, [] {});
    Check(auth.Read().data == rotated.data, "B's stale initial snapshot replaced its latest grant");
    Check(Read(home / L"config.toml") == unchangedConfig &&
        Read(home / L"conversation-fixture.sqlite") == "conversation bytes",
        "Activation changed configuration or conversations");
    const auto before = auth.Read();
    Refuses(FailureCode::busy, [&] {
      store.Activate(a.id, auth, [] { throw Failure(FailureCode::busy); });
    });
    Check(auth.Read() == before, "A refused writer check changed authentication");

    // The installed official client can migrate preferences from JSON to a
    // separate settings database. Never switch against its obsolete JSON shadow.
    const auto database = home / L".codex-global-state.sqlite";
    const auto beforeSettings = auth.Read(LocalSettings::fileName);
    Write(database, "unsupported official settings database");
    Refuses(FailureCode::settingsUnavailable, [&] { store.Activate(a.id, auth, [] {}); });
    Check(auth.Read() == before && Read(home / L".codex-global-state.json") == beforeSettings.data &&
        Read(database) == "unsupported official settings database",
        "Unsupported settings storage changed the account or preferences");
    std::filesystem::remove(database);

    // Mutate after preparation, immediately before replacement. The new file
    // belongs to the external writer and must survive refusal and recovery.
    int observations = 0;
    Refuses(FailureCode::sourceChanged, [&] {
      store.Activate(a.id, auth, [&] {
        if (++observations == 2) Write(home / L"auth.json", a.data);
      });
    });
    Check(auth.Read().data == a.data, "A concurrent writer was overwritten");
    auto interrupted = Json::parse(Read(privateRoot / L"switch.json"));
    interrupted["state"] = "prepared";
    Write(privateRoot / L"switch.json", interrupted.dump());
    Write(home / L"auth.json", b.data);
    Refuses(FailureCode::recoveryConflict, [&] { store.Activate(a.id, auth, [] {}); });
    Check(auth.Read().data == b.data, "Unrecognized recovery overwrote another grant");
    // Restore a recognized prepared-state preimage, then let the next operation recover it.
    Write(home / L"auth.json", rotated.data);
    store.Activate(a.id, auth, [] {});
    Check(auth.Read().data == a.data, "Recognized interrupted operation did not recover");
    store.Remove(b.id);
    Refuses(FailureCode::accountNotFound, [&] { store.Saved(b.id); });
    Check(auth.Read().data == a.data, "Removing a saved login changed live authentication");
  }
  {
    AccountStore reopened(privateRoot);
    Check(reopened.Saved(a.id).data == a.data && reopened.Summaries(a.id).size() == 1,
          "Saved accounts did not survive owner restart");
  }
  {
    AuthFile auth(home);
    const auto before = auth.Read();
    const auto link = home / L"unexpected-hardlink";
    Check(CreateHardLinkW(link.c_str(), (home / L"auth.json").c_str(), nullptr) != FALSE,
          "Hardlink fixture unavailable");
    Refuses(FailureCode::unsafePath, [&] { auth.Read(); });
    DeleteFileW(link.c_str());
    Check(auth.Read().data == before.data, "Hardlink refusal changed login bytes");
    const auto stage = ".loongpass-codex-auth-" + std::string(32, 'c');
    Write(home / loongpass::Wide(stage), "unrecognized existing stage");
    Refuses(FailureCode::unavailable, [&] { auth.Replace(b.data, auth.Read(), stage, "auth.json", [] {}); });
    Check(Read(home / loongpass::Wide(stage)) == "unrecognized existing stage",
          "Stage collision deleted another file");
  }
  std::cout << "Codex transaction checks passed: A/B/A, latest grants, restart, CAS, recovery, isolation and unsafe files\n";
}

void ActivationChecks() {
  std::vector<std::string> steps;
  auto run = [&](bool running, bool rejected) {
    return RunActivation("workspace-b", [&](bool& wasRunning) {
      steps.push_back("quit"); wasRunning = running;
    }, [&] {
      steps.push_back("policy");
      return AuthPolicy(rejected ? Json{{"cli_auth_credentials_store", "keyring"}} :
                                   Json{{"cli_auth_credentials_store", "file"}});
    }, [&] { steps.push_back("apply"); }, [&] { steps.push_back("open"); return true; });
  };
  Check(run(false, false) == "opened" && steps == std::vector<std::string>{"quit", "policy", "apply", "open"},
        "Successful activation did not open a previously stopped desktop");
  steps.clear();
  Refuses(FailureCode::unsupportedStore, [&] { run(true, true); });
  Check(steps == std::vector<std::string>{"quit", "policy", "open"}, "Failed activation did not restore prior desktop");
  steps.clear();
  Refuses(FailureCode::unsupportedStore, [&] { run(false, true); });
  Check(steps == std::vector<std::string>{"quit", "policy"}, "Refusal opened a previously stopped desktop");
  steps.clear();
  Refuses(FailureCode::busy, [&] {
    RunActivation("workspace-b", [&](bool& wasRunning) {
      wasRunning = true; throw Failure(FailureCode::busy);
    }, [] { return AuthPolicy({{"cli_auth_credentials_store", "file"}}); }, [] {},
    [&] { steps.push_back("open"); return true; });
  });
  Check(steps == std::vector<std::string>{"open"}, "Partially stopped desktop was not restored");
  std::cout << "Codex activation checks passed: success auto-opens, policy refusal, prior/partial desktop restoration\n";
}

void PackageChecks() {
  TemporaryDirectory temporary;
  std::filesystem::create_directories(temporary.path / L"app/resources");
  Write(temporary.path / L"app/Desktop.exe", "synthetic executable");
  Write(temporary.path / L"app/resources/codex.exe", "synthetic CLI");
  Json metadata = {{"root", temporary.path.u8string()}, {"family", "Synthetic.Codex_Family"},
      {"apps", Json::array({{{"id", "DesktopApp"}, {"exe", "app/Desktop.exe"}},
                           {{"id", "ExtensionHost"}, {"exe", "app/resources/plugins/host.exe"}},
                           {{"id", "CommandRunner"}, {"exe", "app/resources/command-runner.exe"}}})}};
  const auto client = DesktopClient::Resolve(metadata);
  Check(client.applicationId == L"Synthetic.Codex_Family!DesktopApp" &&
      client.executable == temporary.path / L"app/resources/codex.exe",
      "Package helper applications obscured the actual desktop");
  metadata["apps"].push_back({{"id", "AmbiguousDesktop"}, {"exe", "app/Other.exe"}});
  Refuses(FailureCode::unavailable, [&] { DesktopClient::Resolve(metadata); });
  metadata["apps"].back()["exe"] = "../outside.exe";
  Refuses(FailureCode::unavailable, [&] { DesktopClient::Resolve(metadata); });
  std::cout << "Codex package checks passed: desktop capability, helper apps, ambiguity and path traversal\n";
}

void ExternalPermissionChecks(const Credential& credential) {
  TemporaryDirectory temporary;
  AuthFile auth(temporary.path / L"home");
  auth.Replace(credential.data, auth.Read(), ".loongpass-codex-auth-" + std::string(32, 'd'), "auth.json", [] {});
  const auto path = auth.root() / L"auth.json";
  auto grant = [&](DWORD rights) {
    BYTE sid[SECURITY_MAX_SID_SIZE] = {}; DWORD size = sizeof(sid);
    Check(CreateWellKnownSid(WinWorldSid, nullptr, sid, &size) != FALSE, "Permission fixture SID unavailable");
    PACL old = nullptr, updated = nullptr; PSECURITY_DESCRIPTOR descriptor = nullptr;
    Check(GetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()), SE_FILE_OBJECT, DACL_SECURITY_INFORMATION,
        nullptr, nullptr, &old, nullptr, &descriptor) == ERROR_SUCCESS, "Permission fixture ACL unavailable");
    EXPLICIT_ACCESSW access = {}; access.grfAccessPermissions = rights; access.grfAccessMode = SET_ACCESS;
    access.Trustee.TrusteeForm = TRUSTEE_IS_SID; access.Trustee.ptstrName = reinterpret_cast<wchar_t*>(sid);
    const auto merged = SetEntriesInAclW(1, &access, old, &updated);
    const auto result = merged == ERROR_SUCCESS ? SetNamedSecurityInfoW(const_cast<wchar_t*>(path.c_str()),
        SE_FILE_OBJECT, DACL_SECURITY_INFORMATION, nullptr, nullptr, updated, nullptr) : merged;
    if (updated) LocalFree(updated); LocalFree(descriptor);
    Check(result == ERROR_SUCCESS, "Permission fixture update failed");
  };
  grant(FILE_GENERIC_READ);
  Check(auth.Read().data == credential.data, "An external read-only ACL prevented official-file import");
  grant(FILE_GENERIC_READ | FILE_WRITE_DATA);
  Refuses(FailureCode::unsafePath, [&] { auth.Read(); });
  std::cout << "Codex external permission checks passed: existing readers tolerated, foreign writers refused\n";
}

void ReplacementRaceChecks(const Credential& before, const Credential& target, const Credential& external) {
  TemporaryDirectory temporary;
  AuthFile auth(temporary.path / L"home");
  AuthFile writer(temporary.path / L"writer");
  writer.Replace(external.data, writer.Read(), ".loongpass-codex-auth-" + std::string(32, 'c'), "auth.json", [] {});
  auth.Replace(before.data, auth.Read(), ".loongpass-codex-auth-" + std::string(32, 'e'), "auth.json", [] {});
  const auto expected = auth.Read();
  const auto stage = ".loongpass-codex-auth-" + std::string(32, 'f');
  int checks = 0;
  Refuses(FailureCode::sourceChanged, [&] {
    auth.Replace(target.data, expected, stage, "auth.json", [&] {
      // The commit boundary must re-check writers after it has pinned and
      // displaced the validated preimage. A competing destination wins.
      if (++checks == 2) {
        const auto backup = auth.root() / loongpass::Wide(stage + ".previous");
        const auto changed = CreateFileW(backup.c_str(), GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE |
            FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
        const bool pinned = changed == INVALID_HANDLE_VALUE && GetLastError() == ERROR_SHARING_VIOLATION;
        if (changed != INVALID_HANDLE_VALUE) CloseHandle(changed);
        Check(pinned, "The validated preimage was still writable");
        Check(MoveFileExW((writer.root() / L"auth.json").c_str(), (auth.root() / L"auth.json").c_str(),
            MOVEFILE_WRITE_THROUGH) != FALSE, "Concurrent atomic writer fixture unavailable");
      }
    });
  });
  Check(checks == 2 && auth.Read().data == external.data, "Post-validation writer was silently overwritten");
  Check(Read(auth.root() / loongpass::Wide(stage + ".previous")) == before.data,
        "The actual displaced login was not retained on conflict");
  Refuses(FailureCode::recoveryConflict, [&] {
    auth.RecoverReplacement(stage, "auth.json", Digest(before.data), Digest(target.data), [] {});
  });
  Check(auth.Read().data == external.data, "Recovery overwrote the competing login");
  Check(DeleteFileW((auth.root() / L"auth.json").c_str()) != FALSE, "Crash fixture removal failed");
  auth.RecoverReplacement(stage, "auth.json", Digest(before.data), Digest(target.data), [] {});
  Check(auth.Read().data == before.data, "Displaced-only interrupted replacement did not recover");
  std::cout << "Codex replacement race checks passed: competing destination retained, displaced preimage preserved\n";
}
}  // namespace

int main(int argc, char** argv) {
  using namespace loongpass::codex;
  try {
    if (argc > 1 && std::string(argv[argc - 1]) == "app-server") return ControlledChild();
    Check(argc == 2 || argc == 3, "Pass the shared account contract fixture");
    std::ifstream file(argv[1]);
    Json fixture;
    file >> fixture;
    std::map<std::string, Credential> credentials;
    for (const auto& entry : fixture.at("credentials")) {
      const auto data = entry.at("document").dump();
      if (entry.value("invalid", false)) {
        Refuses(FailureCode::invalidCredential, [&] { Credential value(data); });
        continue;
      }
      Credential value(data);
      Check(value.id == entry.at("expectedId"), "User/workspace identity drifted");
      Check(value.rendererOwnerKey == entry.at("expectedOwner"), "Renderer owner drifted");
      Check(value.data == data, "Original credential bytes were not retained");
      const auto summary = value.Summary(false);
      Check(summary.at("email") == "same@example.invalid", "Identity summary omitted email");
      Check(summary.dump().find("synthetic-refresh") == std::string::npos,
            "Credentials crossed the summary boundary");
      credentials.emplace(entry.at("name").get<std::string>(), std::move(value));
    }
    Check(credentials.at("a").id != credentials.at("b").id,
          "Email was used as the account identity");
    Check(credentials.at("b").id == credentials.at("b-rotated").id,
          "Token rotation changed account identity");
    if (argc == 3 && std::string(argv[2]) == "replacement") {
      ReplacementRaceChecks(credentials.at("a"), credentials.at("b"), credentials.at("b-rotated"));
      return 0;
    }
    for (const auto& entry : fixture.at("settings")) {
      const auto data = entry.at("document").dump();
      const auto& source = credentials.at(entry.at("source").get<std::string>());
      const auto& target = credentials.at(entry.at("target").get<std::string>());
      auto transfer = [&] { return LocalSettings::Transfer(data, source, target); };
      if (entry.value("invalid", false)) Refuses(FailureCode::settingsUnavailable, transfer);
      else {
        if (entry.contains("expectedActiveOwner")) {
          const auto owner = LocalSettings::ActiveOwner(data);
          const auto& expectedOwner = entry.at("expectedActiveOwner");
          Check(expectedOwner.is_null() ? !owner : owner && *owner == expectedOwner,
                "Renderer owner was not recognized");
        }
        Check(Json::parse(transfer()) == entry.at("expected"),
              "Local preferences or account-owned caches crossed the wrong boundary");
      }
    }
    const auto legacy = fixture.at("legacySettings").get<std::string>();
    Check(LocalSettings::Transfer(legacy, credentials.at("a"), credentials.at("b")) == legacy,
          "Legacy preferences lost exact byte preservation");
    AuthPolicy policy({{"cli_auth_credentials_store", "file"},
                       {"forced_chatgpt_workspace_id", "synthetic-workspace-a"}});
    policy.Validate("synthetic-workspace-a");
    Refuses(FailureCode::restricted, [&] { policy.Validate("synthetic-workspace-b"); });
    for (const auto* store : {"auto", "keyring", "ephemeral", "future"}) {
      Refuses(FailureCode::unsupportedStore, [&] {
        AuthPolicy unsupported({{"cli_auth_credentials_store", store}});
      });
    }
    Refuses(FailureCode::restricted, [] {
      AuthPolicy restricted({{"cli_auth_credentials_store", "file"},
                             {"forced_login_method", "api"}});
    });
    Check(DecodeBase64(EncodeBase64(legacy)) == legacy, "Private credential encoding changed bytes");
    TransactionChecks(fixture, credentials);
    RuntimeChecks(credentials);
    ActivationChecks();
    PackageChecks();
    ExternalPermissionChecks(credentials.at("a"));
    ReplacementRaceChecks(credentials.at("a"), credentials.at("b"), credentials.at("b-rotated"));
    std::cout << "Codex native contract checks passed: identities, unknown fields, local preference isolation, policy\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "Codex native check failed: " << error.what() << '\n';
    return 1;
  }
}
