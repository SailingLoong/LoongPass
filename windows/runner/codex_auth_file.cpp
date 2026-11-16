#include "codex_auth_file.h"

#include <windows.h>
#include <aclapi.h>
#include <sddl.h>

#include <array>
#include <vector>

namespace loongpass::codex {
namespace {
void Require(bool value, FailureCode code = FailureCode::unsafePath) {
  if (!value) throw Failure(code);
}
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  explicit Handle(HANDLE handle = INVALID_HANDLE_VALUE) : value(handle) {}
  ~Handle() { if (valid()) CloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value(other.value) { other.value = INVALID_HANDLE_VALUE; }
  bool valid() const { return value != nullptr && value != INVALID_HANDLE_VALUE; }
};
using LocalMemory = std::unique_ptr<void, decltype(&LocalFree)>;

// Official Codex files can retain the normal Windows administrator ACL. This
// differs from the application's private store, whose stricter owner is reused
// through NativeAccountFile. Newly staged credentials use user/SYSTEM only.
class Security {
 public:
  Security() {
    HANDLE raw = nullptr;
    Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw) != FALSE);
    Handle token(raw);
    DWORD count = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &count);
    Require(count > 0);
    token_.resize(count);
    Require(GetTokenInformation(token.value, TokenUser, token_.data(), count, &count) != FALSE);
    user_ = reinterpret_cast<TOKEN_USER*>(token_.data())->User.Sid;
    DWORD length = static_cast<DWORD>(system_.size());
    Require(CreateWellKnownSid(WinLocalSystemSid, nullptr, system_.data(), &length) != FALSE);
    length = static_cast<DWORD>(administrators_.size());
    Require(CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, administrators_.data(), &length) != FALSE);
    wchar_t* rawSid = nullptr;
    Require(ConvertSidToStringSidW(user_, &rawSid) != FALSE);
    LocalMemory sid(rawSid, LocalFree);
    const auto descriptor = L"O:" + std::wstring(rawSid) + L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + rawSid + L")";
    Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(descriptor.c_str(),
        SDDL_REVISION_1, &descriptor_, nullptr) != FALSE);
    attributes_ = {static_cast<DWORD>(sizeof(SECURITY_ATTRIBUTES)), descriptor_, FALSE};
  }
  ~Security() { if (descriptor_) LocalFree(descriptor_); }
  SECURITY_ATTRIBUTES* attributes() { return &attributes_; }
  void Validate(HANDLE file) const {
    PSID owner = nullptr;
    PACL acl = nullptr;
    PSECURITY_DESCRIPTOR raw = nullptr;
    Require(GetSecurityInfo(file, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
        &owner, nullptr, &acl, nullptr, &raw) == ERROR_SUCCESS);
    LocalMemory descriptor(raw, LocalFree);
    Require(owner && EqualSid(owner, user_) && acl && IsValidAcl(acl));
    for (DWORD index = 0; index < acl->AceCount; ++index) {
      void* rawAce = nullptr;
      Require(GetAce(acl, index, &rawAce) != FALSE);
      const auto* header = static_cast<ACE_HEADER*>(rawAce);
      if ((header->AceFlags & INHERIT_ONLY_ACE) != 0) continue;
      if (header->AceType == ACCESS_DENIED_ACE_TYPE) continue;
      Require(header->AceType == ACCESS_ALLOWED_ACE_TYPE);
      const auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(rawAce);
      PSID trustee = const_cast<DWORD*>(&ace->SidStart);
      const bool trusted = EqualSid(trustee, user_) ||
          EqualSid(trustee, const_cast<unsigned char*>(system_.data())) ||
          EqualSid(trustee, const_cast<unsigned char*>(administrators_.data()));
      constexpr DWORD write = FILE_WRITE_DATA | FILE_APPEND_DATA | FILE_WRITE_EA |
          FILE_WRITE_ATTRIBUTES | FILE_DELETE_CHILD | DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_WRITE | GENERIC_ALL;
      // The official client owns existing read access (including its Windows
      // sandbox group). Reject foreign writers; our saved/staged grants still
      // use the private user/SYSTEM descriptor above.
      Require(trusted || (ace->Mask & write) == 0);
    }
  }

 private:
  std::vector<unsigned char> token_;
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_ = {}, administrators_ = {};
  PSID user_ = nullptr;
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
  SECURITY_ATTRIBUTES attributes_ = {};
};

bool Stage(const std::string& name) {
  for (const auto* prefix : {".loongpass-codex-auth-", ".loongpass-codex-settings-"}) {
    const auto size = std::char_traits<char>::length(prefix);
    if (name.rfind(prefix, 0) == 0 && name.size() == size + 32 &&
        name.find_first_not_of("0123456789abcdef", size) == std::string::npos) return true;
  }
  return false;
}

bool Settings(const std::string& name) {
  return name == LocalSettings::fileName || name.rfind(".loongpass-codex-settings-", 0) == 0;
}

BY_HANDLE_FILE_INFORMATION Information(HANDLE file, bool directory, size_t limit) {
  BY_HANDLE_FILE_INFORMATION info = {};
  Require(GetFileType(file) == FILE_TYPE_DISK && GetFileInformationByHandle(file, &info));
  Require((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0 &&
      ((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory);
  if (!directory) Require(info.nNumberOfLinks == 1 &&
      ((static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow) <= limit);
  return info;
}

Json Identity(const BY_HANDLE_FILE_INFORMATION& info) {
  return Json::array({info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow});
}

std::string Fingerprint(HANDLE file, const BY_HANDLE_FILE_INFORMATION& info) {
  FILE_BASIC_INFO basic = {};
  Require(GetFileInformationByHandleEx(file, FileBasicInfo, &basic, sizeof(basic)) != FALSE);
  return Json::array({Identity(info), info.dwFileAttributes, info.nFileSizeHigh, info.nFileSizeLow,
      basic.CreationTime.QuadPart, basic.LastWriteTime.QuadPart, basic.ChangeTime.QuadPart}).dump();
}
}  // namespace

struct AuthFile::State {
  explicit State(std::filesystem::path path) : root(std::move(path)) {
    Require(root.is_absolute() && root == root.lexically_normal());
    std::vector<std::filesystem::path> ancestors;
    for (auto current = root.parent_path(); !current.empty();) {
      ancestors.push_back(current);
      const auto parent = current.parent_path();
      if (parent == current) break;
      current = parent;
    }
    for (auto current = ancestors.rbegin(); current != ancestors.rend(); ++current) {
      Handle directory(CreateFileW(current->c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
          FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
          FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      Require(directory.valid());
      Information(directory.value, true, 0);
      directories.push_back(std::move(directory));
    }
    if (GetFileAttributesW(root.c_str()) == INVALID_FILE_ATTRIBUTES) {
      Require(GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND);
      Require(CreateDirectoryW(root.c_str(), security.attributes()) != FALSE);
    }
    Handle directory(CreateFileW(root.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
        FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    Require(directory.valid());
    Information(directory.value, true, 0);
    directories.push_back(std::move(directory));
    security.Validate(directories.back().value);
    identity = Identity(Information(directories.back().value, true, 0));
  }
  void Validate() const {
    Require(Identity(Information(directories.back().value, true, 0)) == identity, FailureCode::sourceChanged);
    security.Validate(directories.back().value);
  }
  std::filesystem::path Path(const std::string& name) const {
    Require(name == "auth.json" || name == LocalSettings::fileName || Stage(name));
    return root / std::filesystem::u8path(name);
  }
  std::filesystem::path root;
  mutable Security security;
  std::vector<Handle> directories;
  Json identity;
};

AuthFile::AuthFile(const std::filesystem::path& root) : state_(std::make_unique<State>(root)) {}
AuthFile::~AuthFile() = default;
const std::filesystem::path& AuthFile::root() const { return state_->root; }
std::string AuthFile::RootRevision() const { state_->Validate(); return state_->identity.dump(); }

AuthFile::Snapshot AuthFile::Read(const std::string& name) const {
  state_->Validate();
  const auto path = state_->Path(name);
  Handle file(CreateFileW(path.c_str(), GENERIC_READ | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  if (!file.valid()) {
    Require(GetLastError() == ERROR_FILE_NOT_FOUND);
    return {std::nullopt, "absent"};
  }
  const auto limit = Settings(name) ? LocalSettings::maximumBytes : 1024 * 1024;
  const auto info = Information(file.value, false, limit);
  state_->security.Validate(file.value);
  const auto before = Fingerprint(file.value, info);
  std::string data(static_cast<size_t>(info.nFileSizeLow), '\0');
  DWORD count = 0;
  Require(ReadFile(file.value, data.data(), static_cast<DWORD>(data.size()), &count, nullptr) && count == data.size());
  Require(Fingerprint(file.value, Information(file.value, false, limit)) == before, FailureCode::sourceChanged);
  Handle named(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Require(named.valid() && Fingerprint(named.value, Information(named.value, false, limit)) == before,
          FailureCode::sourceChanged);
  state_->Validate();
  return {std::move(data), before};
}

void AuthFile::Replace(const std::string& data, const Snapshot& expected,
    const std::string& stage, const std::string& name,
    const std::function<void()>& ensureStopped) const {
  Require(Stage(stage) && (name == "auth.json" || name == LocalSettings::fileName));
  Require(data.size() <= (Settings(name) ? LocalSettings::maximumBytes : 1024 * 1024));
  state_->Validate();
  const auto staged = state_->Path(stage), destination = state_->Path(name);
  struct Cleanup {
    std::filesystem::path path;
    bool created = false;
    Json identity;
    ~Cleanup() {
      if (!created) return;
      Handle named(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
          FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
          OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
      BY_HANDLE_FILE_INFORMATION info = {};
      if (named.valid() && GetFileInformationByHandle(named.value, &info) && Identity(info) == identity)
        DeleteFileW(path.c_str());
    }
  } cleanup{staged};
  {
    Handle file(CreateFileW(staged.c_str(), GENERIC_WRITE | READ_CONTROL, 0,
        state_->security.attributes(), CREATE_NEW,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
    Require(file.valid(), FailureCode::unavailable);
    cleanup.created = true;
    cleanup.identity = Identity(Information(file.value, false, data.size()));
    DWORD written = 0;
    Require(WriteFile(file.value, data.data(), static_cast<DWORD>(data.size()), &written, nullptr) &&
        written == data.size() && FlushFileBuffers(file.value), FailureCode::unavailable);
  }
  ensureStopped();
  Require(Read(name) == expected && Read(stage).data == data, FailureCode::sourceChanged);
  state_->Validate();
  const DWORD flags = MOVEFILE_WRITE_THROUGH | (expected.data ? MOVEFILE_REPLACE_EXISTING : 0);
  Require(MoveFileExW(staged.c_str(), destination.c_str(), flags) != FALSE,
          FailureCode::sourceChanged);
  Require(Read(name).data == data, FailureCode::sourceChanged);
}

void AuthFile::DiscardStage(const std::string& name, const std::string& digest) const {
  Require(Stage(name), FailureCode::recoveryConflict);
  const auto saved = Read(name);
  if (!saved.data) return;
  Require(saved.digest() == digest && Read(name) == saved, FailureCode::recoveryConflict);
  Require(DeleteFileW(state_->Path(name).c_str()) != FALSE, FailureCode::recoveryConflict);
}

void AuthFile::WithExclusive(const std::function<void()>& action) const {
  state_->Validate();
  Handle file(CreateFileW((root() / L".loongpass-account-switch.lock").c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL, FILE_SHARE_READ | FILE_SHARE_WRITE,
      state_->security.attributes(), OPEN_ALWAYS, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Require(file.valid());
  Information(file.value, false, 0);
  state_->security.Validate(file.value);
  OVERLAPPED range = {};
  Require(LockFileEx(file.value, LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
      0, MAXDWORD, MAXDWORD, &range) != FALSE, FailureCode::busy);
  action();
}
}  // namespace loongpass::codex
