// Build as a standalone Windows target. Including the implementation keeps the
// temporary-root seam private to this test translation unit.
#include "../windows/runner/native_storage.cpp"

#include <iostream>

namespace {
template <typename Condition>
void Check(Condition condition) {
  if (!condition) throw std::runtime_error("Storage check failed");
}

template <typename Operation>
void Refuses(Operation operation) {
  bool refused = false;
  try {
    operation();
  } catch (...) {
    refused = true;
  }
  Check(refused);
}

DWORD ProbeOwner(const std::filesystem::path& root) {
  std::vector<wchar_t> executable(32768);
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  Check(length > 0 && length < executable.size());
  std::wstring command = L"\"" + std::wstring(executable.data(), length) +
                         L"\" --probe-owner \"" + root.wstring() + L"\"";
  STARTUPINFOW startup = {};
  startup.cb = static_cast<DWORD>(sizeof(startup));
  PROCESS_INFORMATION process = {};
  Check(CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE, 0,
                        nullptr, nullptr, &startup, &process));
  loongpass::Handle child(process.hProcess), thread(process.hThread);
  if (WaitForSingleObject(child.get(), 30000) != WAIT_OBJECT_0) {
    TerminateProcess(child.get(), 3);
    WaitForSingleObject(child.get(), 30000);
    throw std::runtime_error("Storage child timed out");
  }
  DWORD code = 0;
  Check(GetExitCodeProcess(child.get(), &code));
  return code;
}

void GiveEveryoneAccess(const std::filesystem::path& path) {
  PSECURITY_DESCRIPTOR raw = nullptr;
  Check(ConvertStringSecurityDescriptorToSecurityDescriptorW(
      L"D:P(A;;FA;;;WD)", SDDL_REVISION_1, &raw, nullptr));
  loongpass::LocalMemory descriptor(raw, LocalFree);
  BOOL present = FALSE, defaulted = FALSE;
  PACL acl = nullptr;
  Check(GetSecurityDescriptorDacl(raw, &present, &acl, &defaulted) && present);
  loongpass::Handle file(CreateFileW(path.c_str(), READ_CONTROL | WRITE_DAC,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Check(file.valid() && SetSecurityInfo(
      file.get(), SE_FILE_OBJECT,
      DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
      nullptr, nullptr, acl, nullptr) == ERROR_SUCCESS);
}

class TemporaryStore {
 public:
  TemporaryStore() {
    wchar_t buffer[MAX_PATH + 1] = {};
    const DWORD length = GetTempPathW(MAX_PATH, buffer);
    Check(length > 0 && length < MAX_PATH);
    root = std::filesystem::path(buffer) /
           loongpass::Wide("loongpass-storage-checks-" + loongpass::RandomHex(16));
  }
  ~TemporaryStore() {
    std::error_code error;
    std::filesystem::remove_all(root, error);
  }
  std::filesystem::path root;
};
}  // namespace

int wmain(int argc, wchar_t** argv) {
  using namespace loongpass;
  if (argc == 3 && std::wstring(argv[1]) == L"--probe-owner") {
    try {
      FileOwner child{std::filesystem::path(argv[2])};
      return 0;
    } catch (...) {
      return 2;
    }
  }
  try {
    TemporaryStore fixture;
    const std::string payload =
        R"({"version":1,"accounts":{"synthetic":{"claims":{"today":{"state":"unknown"}}}}})";
    {
      FileOwner owner(fixture.root);
      Check(DocumentOperation(owner, "readAccountDocument", {}) ==
            Json({{"revision", 0}, {"payload", "{}"}}));
      const auto written = DocumentOperation(
          owner, "writeAccountDocument",
          {{"expectedRevision", 0}, {"payload", payload}});
      Check(written["revision"] == 1);
      Refuses([&] {
        DocumentOperation(owner, "writeAccountDocument",
                          {{"expectedRevision", 0}, {"payload", "{}"}});
      });
      Refuses([&] {
        DocumentOperation(owner, "writeAccountDocument",
                          {{"expectedRevision", true}, {"payload", "{}"}});
      });
      Refuses([&] { FileOwner second(fixture.root); });
      Check(ProbeOwner(fixture.root) == 2);
      Refuses([&] { owner.Read("../accounts.json"); });
      Check(owner.Read("accounts.json")["payload"] == payload);
    }
    {
      FileOwner reopened(fixture.root);
      Check(DocumentOperation(reopened, "readAccountDocument", {}) ==
            Json({{"revision", 1}, {"payload", payload}}));
      const auto link = fixture.root / L"linked.json";
      Check(CreateHardLinkW(link.c_str(),
                            (fixture.root / L"accounts.json").c_str(), nullptr));
      Refuses([&] { reopened.Read("linked.json"); });
      Refuses([&] { reopened.Write(Json::object(), "accounts.json"); });
      Check(DeleteFileW(link.c_str()));
    }
    Check(ProbeOwner(fixture.root) == 0);
    std::cout << "PASS document CAS, restart, preserved unknown intent and links\n";
    {
      FileOwner owner(fixture.root);
      owner.Write({{"synthetic", true}}, "weak.json");
      GiveEveryoneAccess(fixture.root / L"weak.json");
      Refuses([&] { owner.Read("weak.json"); });
    }
    std::cout << "PASS broad credential-file permissions are refused\n";

    TemporaryStore vault_fixture;
    {
      FileOwner vault(vault_fixture.root);
      const std::string key(64, 'a');
      const Json record = {
          {"schema", 1}, {"revision", 1}, {"state", "active"},
          {"domain", "www.workbuddy.cn"}, {"endpoint", "www.workbuddy.cn"},
          {"uid", "synthetic-account"}, {"accessToken", "synthetic-access"},
          {"refreshToken", "synthetic-refresh"}, {"expiresAt", 1800000000000LL}};
      Check(VaultOperation(vault, "compareExchangeWorkBuddyVault",
                           {{"key", key}, {"expected", nullptr}, {"value", record}}) == true);
      Check(VaultOperation(vault, "compareExchangeWorkBuddyVault",
                           {{"key", key}, {"expected", nullptr}, {"value", record}}) == false);
      Check(VaultOperation(vault, "readWorkBuddyVault", {{"key", key}}) == record);
      auto changed_identity = record;
      changed_identity["revision"] = 2;
      changed_identity["uid"] = "different-synthetic-account";
      Refuses([&] {
        VaultOperation(vault, "compareExchangeWorkBuddyVault",
                       {{"key", key}, {"expected", 1}, {"value", changed_identity}});
      });
      Check(VaultOperation(vault, "readWorkBuddyVault", {{"key", key}}) == record);
      auto pending = record;
      pending["revision"] = 2;
      pending["state"] = "rotationPending";
      Check(VaultOperation(vault, "compareExchangeWorkBuddyVault",
                           {{"key", key}, {"expected", 1}, {"value", pending}}) == true);
      const Json revoked = {{"schema", 1}, {"revision", 3}, {"state", "revoked"}};
      Check(VaultOperation(vault, "compareExchangeWorkBuddyVault",
                           {{"key", key}, {"expected", 2}, {"value", revoked}}) == true);
      Check(vault.Read("accounts.json").dump().find("synthetic-access") == std::string::npos);
      auto resurrected = record;
      resurrected["revision"] = 4;
      Check(VaultOperation(vault, "compareExchangeWorkBuddyVault",
                           {{"key", key}, {"expected", 3}, {"value", resurrected}}) == false);
      vault.PrepareJournal();
      Handle journal(CreateFileW((vault_fixture.root / L"workbuddy-intents.jsonl").c_str(),
                                 GENERIC_READ | GENERIC_WRITE,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                                 OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      Check(journal.valid());
      OVERLAPPED range = {};
      Check(LockFileEx(journal.get(), LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                       0, MAXDWORD, MAXDWORD, &range));
      vault.FlushJournal();
      Check(UnlockFileEx(journal.get(), 0, MAXDWORD, MAXDWORD, &range));
    }
    std::cout << "PASS vault CAS, rotation, revocation and flush with journal locked\n";

    TemporaryStore qoder_fixture;
    {
      FileOwner qoder(qoder_fixture.root);
      const Json args = {{"region", "cn"}};
      const auto grant = QoderOperation(qoder, "newGrant", args);
      Check(grant["verifier"].get<std::string>().size() == 43);
      Check(grant["challenge"].get<std::string>().size() == 43);
      Check(Base64Url(Sha256("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")) ==
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
      const auto other = QoderOperation(qoder, "newGrant", args);
      Check(other["machineId"] == grant["machineId"]);
      Check(other["nonce"] != grant["nonce"]);
      Refuses([&] {
        QoderOperation(qoder, "cancelGrant",
                       {{"region", "global"}, {"nonce", grant["nonce"]}});
      });
      const auto committed = QoderOperation(
          qoder, "commitGrant", {{"region", "cn"}, {"nonce", grant["nonce"]},
                                  {"expectedRevision", 0}, {"payload", payload}});
      Check(committed["revision"] == 1);
      Check(QoderOperation(qoder, "cancelGrant", {{"region", "cn"}, {"nonce", grant["nonce"]}})
                ["status"] == "completed");
      Check(QoderOperation(qoder, "cancelGrant", {{"region", "cn"}, {"nonce", other["nonce"]}})
                ["status"] == "cancelled");
      Refuses([&] {
        QoderOperation(qoder, "commitGrant", {{"region", "cn"}, {"nonce", other["nonce"]},
                                              {"expectedRevision", 1}, {"payload", "{}"}});
      });
      Check(QoderOperation(qoder, "read", args)["payload"] == payload);
      const auto uncertain = QoderOperation(qoder, "newGrant", args);
      Handle block_replacement(CreateFileW(
          (qoder_fixture.root / L"accounts.json").c_str(), GENERIC_READ,
          FILE_SHARE_READ, nullptr, OPEN_EXISTING,
          FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      Check(block_replacement.valid());
      Refuses([&] {
        QoderOperation(qoder, "commitGrant",
                       {{"region", "cn"}, {"nonce", uncertain["nonce"]},
                        {"expectedRevision", 1}, {"payload", "{}"}});
      });
      block_replacement.Close();
      Check(QoderOperation(qoder, "cancelGrant",
                           {{"region", "cn"}, {"nonce", uncertain["nonce"]}})
                ["status"] == "unknown");
      Check(QoderOperation(qoder, "read", args)["revision"] == 1);
      Check(QoderOperation(qoder, "read", args)["payload"] == payload);
    }
    std::cout << "PASS PKCE, installation identity and grant commit/cancel\n";
    return 0;
  } catch (...) {
    std::cerr << "FAIL native storage synthetic checks\n";
    return 1;
  }
}
