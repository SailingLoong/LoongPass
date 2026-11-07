#include "native_storage.h"

#include <aclapi.h>
#include <sddl.h>
#include <shlobj.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <limits>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <utility>

namespace loongpass {
namespace {
constexpr size_t kDocumentLimit = 4 * 1024 * 1024;
constexpr size_t kFileLimit = 5 * 1024 * 1024;
constexpr size_t kVaultLimit = 1024 * 1024;
constexpr size_t kJournalLimit = 16 * 1024 * 1024;

template <typename Condition>
void Require(Condition condition) {
  if (!condition) throw std::runtime_error("Storage unavailable");
}

class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle() { Close(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value_(other.value_) {
    other.value_ = INVALID_HANDLE_VALUE;
  }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) {
      Close();
      value_ = other.value_;
      other.value_ = INVALID_HANDLE_VALUE;
    }
    return *this;
  }
  bool valid() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }
  HANDLE get() const { return value_; }
  void Close() {
    if (valid()) CloseHandle(value_);
    value_ = INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE value_;
};

using LocalMemory = std::unique_ptr<void, decltype(&LocalFree)>;

class PrivateSecurity {
 public:
  PrivateSecurity() {
    HANDLE raw_token = nullptr;
    Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &raw_token));
    Handle token(raw_token);
    DWORD length = 0;
    GetTokenInformation(token.get(), TokenUser, nullptr, 0, &length);
    Require(length > 0);
    token_user_.resize(length);
    Require(GetTokenInformation(token.get(), TokenUser, token_user_.data(),
                                length, &length));
    user_ = reinterpret_cast<TOKEN_USER*>(token_user_.data())->User.Sid;
    DWORD system_length = static_cast<DWORD>(system_.size());
    Require(CreateWellKnownSid(WinLocalSystemSid, nullptr, system_.data(),
                               &system_length));
    wchar_t* raw_sid = nullptr;
    Require(ConvertSidToStringSidW(user_, &raw_sid));
    LocalMemory sid(raw_sid, LocalFree);
    const std::wstring text = L"O:" + std::wstring(raw_sid) +
        L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;" + raw_sid + L")";
    Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(
        text.c_str(), SDDL_REVISION_1, &descriptor_, nullptr));
    attributes_ = {static_cast<DWORD>(sizeof(SECURITY_ATTRIBUTES)), descriptor_, FALSE};
  }
  ~PrivateSecurity() { LocalFree(descriptor_); }
  SECURITY_ATTRIBUTES* attributes() { return &attributes_; }
  void Validate(HANDLE handle, bool protected_required) const;

 private:
  std::vector<unsigned char> token_user_;
  std::array<unsigned char, SECURITY_MAX_SID_SIZE> system_ = {};
  PSID user_ = nullptr;
  PSECURITY_DESCRIPTOR descriptor_ = nullptr;
  SECURITY_ATTRIBUTES attributes_ = {};
};

void PrivateSecurity::Validate(HANDLE handle, bool protected_required) const {
  PSID owner = nullptr;
  PACL acl = nullptr;
  PSECURITY_DESCRIPTOR raw_descriptor = nullptr;
  Require(GetSecurityInfo(handle, SE_FILE_OBJECT,
                         OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                         &owner, nullptr, &acl, nullptr,
                         &raw_descriptor) == ERROR_SUCCESS);
  LocalMemory descriptor(raw_descriptor, LocalFree);
  Require(owner && EqualSid(owner, user_) && acl && IsValidAcl(acl));
  SECURITY_DESCRIPTOR_CONTROL control = 0;
  DWORD revision = 0;
  Require(GetSecurityDescriptorControl(raw_descriptor, &control, &revision));
  Require(!protected_required || (control & SE_DACL_PROTECTED) != 0);
  bool has_user = false, has_system = false;
  for (DWORD index = 0; index < acl->AceCount; ++index) {
    void* raw_ace = nullptr;
    Require(GetAce(acl, index, &raw_ace));
    const auto* header = static_cast<ACE_HEADER*>(raw_ace);
    Require(header->AceType == ACCESS_ALLOWED_ACE_TYPE);
    auto* ace = static_cast<ACCESS_ALLOWED_ACE*>(raw_ace);
    PSID trustee = &ace->SidStart;
    const bool user = EqualSid(trustee, user_) != FALSE;
    const bool system = EqualSid(trustee, const_cast<unsigned char*>(system_.data())) != FALSE;
    Require(user || system);
    if ((header->AceFlags & INHERIT_ONLY_ACE) == 0 &&
        (ace->Mask & FILE_ALL_ACCESS) == FILE_ALL_ACCESS) {
      has_user = has_user || user;
      has_system = has_system || system;
    }
  }
  Require(has_user && has_system);
}

PrivateSecurity& Security() {
  static PrivateSecurity security;
  return security;
}

BY_HANDLE_FILE_INFORMATION FileInformation(HANDLE handle, bool directory,
                                         size_t limit, bool private_node) {
  BY_HANDLE_FILE_INFORMATION info = {};
  Require(GetFileType(handle) == FILE_TYPE_DISK &&
          GetFileInformationByHandle(handle, &info));
  Require((info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0);
  Require(((info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) == directory);
  if (!directory) {
    const auto length = (static_cast<uint64_t>(info.nFileSizeHigh) << 32) |
                        info.nFileSizeLow;
    Require(info.nNumberOfLinks == 1 && length <= limit);
  }
  if (private_node) Security().Validate(handle, directory);
  return info;
}

Handle OpenDirectory(const std::filesystem::path& path, bool private_node) {
  Handle handle(CreateFileW(
      path.c_str(), FILE_READ_ATTRIBUTES | (private_node ? READ_CONTROL : 0),
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  Require(handle.valid());
  FileInformation(handle.get(), true, 0, private_node);
  return handle;
}

class DirectoryOwner {
 public:
  explicit DirectoryOwner(std::filesystem::path root) : root_(std::move(root)) {
    Require(root_.is_absolute() && root_ == root_.lexically_normal());
    std::vector<std::filesystem::path> ancestors;
    for (auto path = root_.parent_path(); !path.empty();) {
      ancestors.push_back(path);
      const auto parent = path.parent_path();
      if (parent == path) break;
      path = parent;
    }
    for (auto item = ancestors.rbegin(); item != ancestors.rend(); ++item)
      ancestors_.push_back(OpenDirectory(*item, false));
    if (!CreateDirectoryW(root_.c_str(), Security().attributes()))
      Require(GetLastError() == ERROR_ALREADY_EXISTS);
    directory_ = OpenDirectory(root_, true);
  }
  const std::filesystem::path& root() const { return root_; }
  void Check() const { FileInformation(directory_.get(), true, 0, true); }

 private:
  std::filesystem::path root_;
  std::vector<Handle> ancestors_;
  Handle directory_;
};

std::string ReadBytes(HANDLE handle, size_t limit) {
  const auto info = FileInformation(handle, false, limit, true);
  const size_t length = static_cast<size_t>(
      (static_cast<uint64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow);
  LARGE_INTEGER start = {};
  Require(SetFilePointerEx(handle, start, nullptr, FILE_BEGIN));
  std::string bytes(length, '\0');
  size_t offset = 0;
  while (offset < length) {
    DWORD count = 0;
    Require(ReadFile(handle, bytes.data() + offset,
                     static_cast<DWORD>(length - offset), &count, nullptr) &&
            count > 0);
    offset += count;
  }
  char extra = 0;
  DWORD count = 0;
  Require(ReadFile(handle, &extra, 1, &count, nullptr) && count == 0);
  return bytes;
}

class FileOwner {
 public:
  explicit FileOwner(const std::filesystem::path& root) : directory_(root) {
    lock_ = Handle(CreateFileW(
        (root / L"owner.lock").c_str(), GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
        FILE_SHARE_READ | FILE_SHARE_WRITE, Security().attributes(), OPEN_ALWAYS,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
    Require(lock_.valid());
    FileInformation(lock_.get(), false, kFileLimit, true);
    OVERLAPPED range = {};
    Require(LockFileEx(lock_.get(),
                       LOCKFILE_EXCLUSIVE_LOCK | LOCKFILE_FAIL_IMMEDIATELY,
                       0, MAXDWORD, MAXDWORD, &range));
  }
  Json Read(const std::string& name, size_t limit = kFileLimit) const {
    directory_.Check();
    const auto path = Path(name);
    Handle file(CreateFileW(path.c_str(), GENERIC_READ | READ_CONTROL,
                            FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
    if (!file.valid()) {
      Require(GetLastError() == ERROR_FILE_NOT_FOUND);
      return nullptr;
    }
    auto value = Json::parse(ReadBytes(file.get(), limit));
    Require(value.is_object());
    return value;
  }
  void Write(const Json& value, const std::string& name,
             size_t limit = kFileLimit) const;
  const std::filesystem::path& root() const { return directory_.root(); }
  void PrepareJournal() const;
  void FlushJournal() const;

 private:
  std::filesystem::path Path(const std::string& name) const {
    Require(!name.empty() && name.size() > 5 &&
            name.compare(name.size() - 5, 5, ".json") == 0 &&
            name.find_first_not_of(
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") ==
                std::string::npos);
    return directory_.root() / Wide(name);
  }
  DirectoryOwner directory_;
  Handle lock_;
};

void FileOwner::Write(const Json& value, const std::string& name,
                      size_t limit) const {
  Require(value.is_object());
  const auto destination = Path(name);
  const std::string bytes = value.dump();
  Require(bytes.size() <= limit);
  Read(name, limit);
  const auto stage = root() / Wide(".write-" + RandomHex(16));
  struct RemoveStage {
    std::filesystem::path path;
    bool created = false;
    ~RemoveStage() { if (created) DeleteFileW(path.c_str()); }
  } cleanup{stage};
  Handle file(CreateFileW(
      stage.c_str(), GENERIC_READ | GENERIC_WRITE | READ_CONTROL, 0,
      Security().attributes(), CREATE_NEW,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
  Require(file.valid());
  cleanup.created = true;
  FileInformation(file.get(), false, limit, true);
  DWORD written = 0;
  Require(WriteFile(file.get(), bytes.data(), static_cast<DWORD>(bytes.size()),
                    &written, nullptr) && written == bytes.size());
  Require(FlushFileBuffers(file.get()));
  file.Close();
  directory_.Check();
  Require(MoveFileExW(stage.c_str(), destination.c_str(),
                      MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH));
  Handle saved(CreateFileW(destination.c_str(),
                          GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
                          FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                          FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH,
                          nullptr));
  Require(saved.valid() && FlushFileBuffers(saved.get()));
  Require(ReadBytes(saved.get(), limit) == bytes);
}

void FileOwner::PrepareJournal() const {
  directory_.Check();
  Handle journal(CreateFileW(
      (root() / L"workbuddy-intents.jsonl").c_str(),
      GENERIC_READ | GENERIC_WRITE | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, Security().attributes(), OPEN_ALWAYS,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
  Require(journal.valid());
  FileInformation(journal.get(), false, kJournalLimit, true);
  Require(FlushFileBuffers(journal.get()));
}

void FileOwner::FlushJournal() const {
  directory_.Check();
  Handle journal(CreateFileW(
      (root() / L"workbuddy-intents.jsonl").c_str(),
      GENERIC_WRITE | FILE_READ_ATTRIBUTES | READ_CONTROL,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_EXISTING,
      FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_WRITE_THROUGH, nullptr));
  Require(journal.valid());
  FileInformation(journal.get(), false, kJournalLimit, true);
  // Dart holds the byte-range lock and performs exact readback before this call.
  // Flush the file's buffered data/metadata. Windows has no POSIX directory fsync
  // equivalent here, and no volume-wide/admin flush is requested.
  Require(FlushFileBuffers(journal.get()));
}

int64_t Integer(const Json& value, int64_t minimum = 0,
                int64_t maximum = (std::numeric_limits<int64_t>::max)()) {
  int64_t number = 0;
  if (value.is_number_unsigned()) {
    const auto unsigned_number = value.get<uint64_t>();
    Require(unsigned_number <= static_cast<uint64_t>(maximum));
    number = static_cast<int64_t>(unsigned_number);
  } else if (value.is_number_integer()) {
    number = value.get<int64_t>();
  } else {
    Require(value.is_number_float());
    const double raw = value.get<double>();
    Require(std::isfinite(raw) && raw >= 0 &&
            raw < 9223372036854775808.0 && std::floor(raw) == raw);
    number = static_cast<int64_t>(raw);
  }
  Require(number >= minimum && number <= maximum);
  return number;
}

std::string Text(const Json& value) {
  Require(value.is_string());
  return value.get<std::string>();
}

Json ReadEnvelope(FileOwner& file, size_t limit = kFileLimit) {
  auto record = file.Read("accounts.json", limit);
  if (record.is_null()) record = {{"revision", 0}, {"payload", "{}"}};
  Integer(record.at("revision"));
  Text(record.at("payload"));
  return record;
}

Json DocumentOperation(FileOwner& file, const std::string& method,
                       const Json& args) {
  const auto current = ReadEnvelope(file);
  const auto revision = Integer(current.at("revision"));
  if (method == "readAccountDocument")
    return {{"revision", revision}, {"payload", current.at("payload")}};
  Require(method == "writeAccountDocument" && args.is_object());
  const auto expected = Integer(args.at("expectedRevision"));
  Require(expected == revision &&
          revision < (std::numeric_limits<int64_t>::max)() - 1);
  const auto payload = Text(args.at("payload"));
  Require(payload.size() <= kDocumentLimit && Json::parse(payload).is_object());
  file.Write({{"revision", revision + 1}, {"payload", payload}}, "accounts.json");
  return {{"revision", revision + 1}};
}

bool VaultKey(const std::string& key) {
  return key.size() == 64 && std::all_of(key.begin(), key.end(), [](char c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
  });
}

void AsciiText(const Json& value, size_t limit) {
  const auto text = Text(value);
  Require(!text.empty() && text.size() <= limit &&
          std::all_of(text.begin(), text.end(), [](unsigned char c) {
            return c >= 33 && c <= 126;
          }));
}

void ValidateVaultRecord(const Json& row) {
  Require(row.is_object() && Integer(row.at("schema"), 1, 1) == 1);
  Integer(row.at("revision"), 1, (std::numeric_limits<int32_t>::max)());
  const auto state = Text(row.at("state"));
  if (state == "revoked") {
    Require(row.size() == 3);
    return;
  }
  Require(state == "active" || state == "rotationPending");
  static const std::set<std::string> fields = {
      "schema", "revision", "state", "domain", "endpoint", "uid",
      "accessToken", "refreshToken", "expiresAt", "registrationId"};
  for (const auto& field : row.items())
    Require(fields.count(field.key()) != 0);
  for (const auto* name : {"domain", "endpoint"}) {
    const auto host = Text(row.at(name));
    Require(host == "www.workbuddy.cn" || host == "www.codebuddy.cn");
  }
  if (row.contains("registrationId")) {
    const auto registration = Text(row.at("registrationId"));
    Require(registration.size() == 32 && std::all_of(registration.begin(), registration.end(), [](char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'); }));
  }
  AsciiText(row.at("uid"), 512);
  AsciiText(row.at("accessToken"), 16384);
  if (row.contains("refreshToken")) AsciiText(row.at("refreshToken"), 16384);
  if (row.contains("expiresAt"))
    Integer(row.at("expiresAt"), 1, 8640000000000000LL);
}

Json ReadVault(FileOwner& file) {
  auto records = file.Read("accounts.json", kVaultLimit);
  if (records.is_null()) return Json::object();
  Require(records.size() <= 16);
  for (const auto& item : records.items()) {
    Require(VaultKey(item.key()));
    ValidateVaultRecord(item.value());
  }
  return records;
}

Json VaultOperation(FileOwner& file, const std::string& method,
                    const Json& args) {
  auto records = ReadVault(file);
  if (method == "listWorkBuddyVaultKeys") {
    auto keys = Json::array();
    for (const auto& item : records.items()) keys.push_back(item.key());
    return keys;
  }
  const auto key = Text(args.at("key"));
  Require(VaultKey(key));
  const auto found = records.find(key);
  const Json previous = found == records.end() ? Json() : *found;
  if (method == "readWorkBuddyVault") return previous;
  Require(method == "compareExchangeWorkBuddyVault");
  const auto& value = args.at("value");
  ValidateVaultRecord(value);
  std::optional<int64_t> expected;
  if (args.contains("expected") && !args.at("expected").is_null())
    expected = Integer(args.at("expected"), 1,
                       (std::numeric_limits<int32_t>::max)());
  const auto old_revision = previous.is_null()
      ? std::optional<int64_t>()
      : std::optional<int64_t>(Integer(previous.at("revision")));
  if (old_revision != expected) return false;
  Require(Integer(value.at("revision")) == expected.value_or(0) + 1);
  const auto state = Text(value.at("state"));
  if (!previous.is_null()) {
    const auto old_state = Text(previous.at("state"));
    if (old_state == "revoked") return false;
    if (state != "revoked") {
      Require((old_state == "active" &&
               (state == "active" || state == "rotationPending")) ||
              (old_state == "rotationPending" && state == "active"));
      for (const auto* identity : {"uid", "domain", "endpoint"})
        Require(previous.at(identity) == value.at(identity));
    }
  } else {
    Require(state == "active" || state == "revoked");
  }
  records[key] = value;
  Require(records.size() <= 16);
  file.Write(records, "accounts.json", kVaultLimit);
  Require(ReadVault(file).at(key) == value);
  return true;
}

std::string Base64Url(const std::vector<unsigned char>& bytes) {
  static constexpr char alphabet[] =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  std::string output;
  uint32_t accumulator = 0;
  int bits = 0;
  for (const auto byte : bytes) {
    accumulator = (accumulator << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      output += alphabet[(accumulator >> bits) & 63];
    }
  }
  if (bits > 0) output += alphabet[(accumulator << (6 - bits)) & 63];
  return output;
}

std::vector<unsigned char> Sha256(const std::string& text) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  Require(BCryptOpenAlgorithmProvider(
      &algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0);
  std::vector<unsigned char> output(32);
  const auto status = BCryptHash(
      algorithm, nullptr, 0,
      reinterpret_cast<PUCHAR>(const_cast<char*>(text.data())),
      static_cast<ULONG>(text.size()), output.data(),
      static_cast<ULONG>(output.size()));
  BCryptCloseAlgorithmProvider(algorithm, 0);
  Require(status >= 0);
  return output;
}

std::string Uuid() {
  auto hex = RandomHex(16);
  hex[12] = '4';
  const int variant = hex[16] <= '9' ? hex[16] - '0' : hex[16] - 'a' + 10;
  hex[16] = "89ab"[variant & 3];
  return hex.substr(0, 8) + "-" + hex.substr(8, 4) + "-" +
         hex.substr(12, 4) + "-" + hex.substr(16, 4) + "-" + hex.substr(20);
}

bool IsUuid(const Json& value) {
  if (!value.is_string()) return false;
  const auto text = value.get<std::string>();
  if (text.size() != 36) return false;
  for (size_t index = 0; index < text.size(); ++index) {
    const auto c = text[index];
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (c != '-') return false;
    } else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                 (c >= 'A' && c <= 'F'))) {
      return false;
    }
  }
  return true;
}

struct QoderGrant {
  std::string state, region;
  std::chrono::steady_clock::time_point expires;
};
std::map<std::string, QoderGrant> qoder_grants;

Json NewQoderGrant(FileOwner& file, const std::string& region) {
  const auto now = std::chrono::steady_clock::now();
  for (auto item = qoder_grants.begin(); item != qoder_grants.end();) {
    if (item->second.expires <= now) item = qoder_grants.erase(item);
    else ++item;
  }
  Require(qoder_grants.size() < 64);
  auto installation = file.Read("installation.json");
  if (installation.is_null()) installation = Json::object();
  if (!installation.contains("machineId")) {
    installation["machineId"] = Uuid();
    file.Write(installation, "installation.json");
  }
  Require(IsUuid(installation.at("machineId")));
  std::vector<unsigned char> entropy(32);
  Require(BCryptGenRandom(nullptr, entropy.data(),
                          static_cast<ULONG>(entropy.size()),
                          BCRYPT_USE_SYSTEM_PREFERRED_RNG) >= 0);
  const auto verifier = Base64Url(entropy);
  SecureZeroMemory(entropy.data(), entropy.size());
  const auto challenge = Base64Url(Sha256(verifier));
  const auto nonce = Uuid();
  qoder_grants.emplace(nonce, QoderGrant{
      "waiting", region, now + std::chrono::minutes(5)});
  return {{"verifier", verifier}, {"challenge", challenge}, {"nonce", nonce},
          {"machineId", installation.at("machineId")}};
}

Json QoderOperation(FileOwner& file, const std::string& method,
                    const Json& args) {
  const auto region = Text(args.at("region"));
  Require(region == "cn" || region == "global");
  if (method == "newGrant") return NewQoderGrant(file, region);
  if (method == "cancelGrant") {
    const auto nonce = Text(args.at("nonce"));
    const auto found = qoder_grants.find(nonce);
    if (found == qoder_grants.end()) return {{"status", "cancelled"}};
    auto& grant = found->second;
    Require(grant.region == region);
    if (grant.state != "completed" && grant.state != "unknown")
      grant.state = "cancelled";
    return {{"status", grant.state}};
  }
  Require(method == "read" || method == "compareAndSet" ||
          method == "commitGrant");
  QoderGrant* grant = nullptr;
  if (method == "commitGrant") {
    const auto found = qoder_grants.find(Text(args.at("nonce")));
    Require(found != qoder_grants.end());
    grant = &found->second;
    Require(grant->state == "waiting" && grant->region == region &&
            grant->expires > std::chrono::steady_clock::now());
  }
  const auto current = ReadEnvelope(file, kVaultLimit);
  const auto revision = Integer(current.at("revision"), 0,
      (std::numeric_limits<int64_t>::max)() - 1);
  if (method == "read")
    return {{"revision", revision}, {"payload", current.at("payload")}};
  const auto expected = Integer(args.at("expectedRevision"));
  Require(expected == revision &&
          expected < (std::numeric_limits<int64_t>::max)() - 1);
  const auto payload = Text(args.at("payload"));
  Require(payload.size() <= kVaultLimit && Json::parse(payload).is_object());
  const Json replacement = {{"revision", expected + 1}, {"payload", payload}};
  Require(replacement.dump().size() <= kVaultLimit);
  if (grant) grant->state = "unknown";
  file.Write(replacement, "accounts.json", kVaultLimit);
  const auto saved = ReadEnvelope(file, kVaultLimit);
  Require(saved.at("revision") == expected + 1 && saved.at("payload") == payload);
  if (grant) grant->state = "completed";
  return {{"revision", expected + 1}};
}

const std::set<std::string> kDocumentScopes = {
    "MiniMax-cn", "MiniMax-global", "TRAE-cn", "ZCode"};
std::mutex storage_mutex;
bool workbuddy_journal_prepared = false;

FileOwner& Store(const std::string& scope) {
  static std::map<std::string, std::unique_ptr<FileOwner>> files;
  Require(kDocumentScopes.count(scope) != 0 ||
          scope == "Qoder-cn" || scope == "Qoder-global" ||
          scope == "WorkBuddy" || scope == "WorkBuddy-switch");
  auto found = files.find(scope);
  if (found == files.end())
    found = files.emplace(scope, std::make_unique<FileOwner>(
        ApplicationDataRoot() / Wide(scope))).first;
  return *found->second;
}
}  // namespace

std::filesystem::path ApplicationDataRoot() {
  static DirectoryOwner application([] {
    wchar_t* raw_path = nullptr;
    Require(SUCCEEDED(SHGetKnownFolderPath(
        FOLDERID_RoamingAppData, KF_FLAG_CREATE, nullptr, &raw_path)));
    std::unique_ptr<wchar_t, decltype(&CoTaskMemFree)> path(raw_path, CoTaskMemFree);
    return std::filesystem::path(raw_path) / L"LoongPass";
  }());
  application.Check();
  return application.root();
}

bool HandleStorageCall(const std::string& channel, const Call& call,
                       std::unique_ptr<Result>& result) {
  const auto& method = call.method_name();
  static const std::set<std::string> documents = {
      "readAccountDocument", "writeAccountDocument"};
  static const std::set<std::string> vault = {
      "listWorkBuddyVaultKeys", "readWorkBuddyVault",
      "compareExchangeWorkBuddyVault"};
  static const std::set<std::string> qoder = {
      "newGrant", "cancelGrant", "read", "compareAndSet", "commitGrant"};
  const bool is_vault = channel == "files" && vault.count(method) != 0;
  const bool is_journal = channel == "files" &&
      (method == "prepareWorkBuddyJournal" || method == "syncWorkBuddyJournal");
  const bool is_document = channel == "files" && documents.count(method) != 0;
  const bool is_qoder = channel == "qoder-accounts" && qoder.count(method) != 0;
  if (!is_vault && !is_journal && !is_document && !is_qoder) return false;
  try {
    std::lock_guard<std::mutex> guard(storage_mutex);
    auto args = Decode(call.arguments());
    if (args.is_null()) args = Json::object();
    Require(args.is_object());
    Json reply;
    if (is_document) {
      const auto scope = Text(args.at("scope"));
      Require(kDocumentScopes.count(scope) != 0);
      reply = DocumentOperation(Store(scope), method, args);
    } else if (is_vault) {
      if (method != "listWorkBuddyVaultKeys" &&
          (!args.contains("key") || !args.at("key").is_string() ||
           !VaultKey(args.at("key").get<std::string>()))) {
        result->Error("InvalidVaultArguments");
        return true;
      }
      reply = VaultOperation(Store("WorkBuddy"), method, args);
    } else if (is_qoder) {
      const auto region = Text(args.at("region"));
      Require(region == "cn" || region == "global");
      reply = QoderOperation(Store("Qoder-" + region), method, args);
    } else if (method == "prepareWorkBuddyJournal") {
      auto& file = Store("WorkBuddy");
      file.PrepareJournal();
      workbuddy_journal_prepared = true;
      reply = Utf8(file.root().wstring());
    } else {
      Require(workbuddy_journal_prepared);
      Store("WorkBuddy").FlushJournal();
    }
    result->Success(Encode(reply));
  } catch (...) {
    result->Error(is_vault ? "WorkBuddyVaultUnavailable" :
                  is_journal ? "NativeJournalUnavailable" : "storage_unavailable");
  }
  return true;
}
}  // namespace loongpass
