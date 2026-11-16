#include "codex_desktop_client.h"
#include "native_support.h"

#include <tlhelp32.h>
#include <shlobj.h>
#include <shellapi.h>
#include <winhttp.h>
#include <wrl/client.h>

#include <algorithm>
#include <map>
#include <set>

namespace loongpass::codex {
namespace {
void Require(bool value, FailureCode code = FailureCode::unavailable) {
  if (!value) throw Failure(code);
}
struct Handle {
  HANDLE value;
  explicit Handle(HANDLE raw) : value(raw) {}
  ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
std::string FileRevision(const std::filesystem::path& path) {
  Handle file(CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_DELETE,
      nullptr, OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT, nullptr));
  BY_HANDLE_FILE_INFORMATION info = {};
  Require(file.value != INVALID_HANDLE_VALUE && GetFileInformationByHandle(file.value, &info));
  Require((info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) == 0);
  return Json::array({info.dwVolumeSerialNumber, info.nFileIndexHigh, info.nFileIndexLow,
      info.ftLastWriteTime.dwHighDateTime, info.ftLastWriteTime.dwLowDateTime,
      info.nFileSizeHigh, info.nFileSizeLow}).dump();
}
std::vector<unsigned char> User(HANDLE process) {
  HANDLE raw = nullptr;
  Require(OpenProcessToken(process, TOKEN_QUERY, &raw) != FALSE, FailureCode::busy);
  Handle token(raw);
  DWORD size = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
  Require(size != 0, FailureCode::busy);
  std::vector<unsigned char> output(size);
  Require(GetTokenInformation(token.value, TokenUser, output.data(), size, &size) != FALSE, FailureCode::busy);
  return output;
}
bool SameUser(HANDLE process) {
  const auto current = User(GetCurrentProcess()), other = User(process);
  return EqualSid(reinterpret_cast<const TOKEN_USER*>(current.data())->User.Sid,
                  reinterpret_cast<const TOKEN_USER*>(other.data())->User.Sid) != FALSE;
}
std::filesystem::path Image(HANDLE process) {
  std::wstring text(32768, 0);
  DWORD size = static_cast<DWORD>(text.size());
  Require(QueryFullProcessImageNameW(process, 0, text.data(), &size) != FALSE, FailureCode::busy);
  text.resize(size);
  return text;
}
bool SamePath(const std::filesystem::path& a, const std::filesystem::path& b) {
  return _wcsicmp(a.c_str(), b.c_str()) == 0;
}
struct Process { DWORD id, parent; std::wstring name; };
std::vector<Process> Processes() {
  Handle snapshot(CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0));
  Require(snapshot.value != INVALID_HANDLE_VALUE, FailureCode::busy);
  PROCESSENTRY32W entry = {}; entry.dwSize = sizeof(entry);
  Require(Process32FirstW(snapshot.value, &entry) != FALSE, FailureCode::busy);
  std::vector<Process> output;
  do { output.push_back({entry.th32ProcessID, entry.th32ParentProcessID, entry.szExeFile}); }
  while (Process32NextW(snapshot.value, &entry));
  Require(GetLastError() == ERROR_NO_MORE_FILES, FailureCode::busy);
  return output;
}
std::set<DWORD> DesktopTree(const DesktopClient& client, const std::vector<Process>& processes) {
  std::set<DWORD> output;
  for (const auto& item : processes) {
    if (_wcsicmp(item.name.c_str(), client.desktop.filename().c_str()) != 0) continue;
    Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, item.id));
    if (!process.value) {
      if (GetLastError() == ERROR_INVALID_PARAMETER) continue;
      throw Failure(FailureCode::busy);
    }
    if (SameUser(process.value) && SamePath(Image(process.value), client.desktop)) output.insert(item.id);
  }
  bool changed = true;
  while (changed) {
    changed = false;
    for (const auto& item : processes)
      if (output.count(item.parent) && output.insert(item.id).second) changed = true;
  }
  return output;
}
void NoOtherWriters(const std::vector<Process>& processes, const std::set<DWORD>& desktop,
                    const Cancelled& cancelled) {
  bool hasNode = false;
  for (const auto& item : processes) {
    if (desktop.count(item.id)) continue;
    const bool cli = _wcsicmp(item.name.c_str(), L"codex.exe") == 0;
    const bool node = _wcsicmp(item.name.c_str(), L"node.exe") == 0;
    if (!cli && !node) continue;
    Handle process(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, item.id));
    if (!process.value) {
      if (GetLastError() == ERROR_INVALID_PARAMETER) continue;
      throw Failure(FailureCode::busy);
    }
    if (!SameUser(process.value)) continue;
    if (cli) throw Failure(FailureCode::busy);
    hasNode = true;
  }
  if (!hasNode) return;
  // Only PIDs leave this query; command lines (which may contain secrets) do not.
  const auto output = RunPowerShell(LR"(
$ErrorActionPreference='Stop';[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$blocked=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object {
 $_.CommandLine -match '(@openai[\\/]codex[\\/]|[\\/]codex\.js(?:"|\s|$))' -and
 (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid).Sid -eq $sid
} | ForEach-Object {[long]$_.ProcessId})
ConvertTo-Json -Compress -InputObject $blocked
)", cancelled);
  const auto ids = Json::parse(output, nullptr, false);
  Require(ids.is_array(), FailureCode::busy);
  for (const auto& id : ids) Require(id.is_number_unsigned() || id.is_number_integer(), FailureCode::busy);
  for (const auto& id : ids) Require(desktop.count(id.get<DWORD>()) != 0, FailureCode::busy);
}
}  // namespace

DesktopClient DesktopClient::Installed(const Cancelled& cancelled) {
  const auto output = RunPowerShell(LR"(
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$p=@(Get-AppxPackage -Name OpenAI.Codex | Where-Object {$_.Status -eq 'Ok' -and $_.SignatureKind -eq 'Store'})
if($p.Count -ne 1){throw 'Unavailable'}
$m=Get-AppxPackageManifest -Package $p[0]
$apps=@($m.Package.Applications.Application | Where-Object {$_.Executable -and $_.Id})
if($apps.Count -ne 1){throw 'Unavailable'}
@{root=$p[0].InstallLocation;family=$p[0].PackageFamilyName;id=$apps[0].Id;exe=$apps[0].Executable} | ConvertTo-Json -Compress
)", cancelled);
  const auto value = Json::parse(output, nullptr, false);
  Require(value.is_object());
  for (const auto* key : {"root", "family", "id", "exe"})
    Require(value.contains(key) && value.at(key).is_string() && !value.at(key).get<std::string>().empty());
  DesktopClient client;
  client.package = std::filesystem::u8path(value.at("root").get<std::string>());
  const auto relative = std::filesystem::u8path(value.at("exe").get<std::string>());
  Require(client.package.is_absolute() && !relative.is_absolute() && !relative.has_root_name());
  for (const auto& part : relative) Require(part != L".." && part != L".");
  client.desktop = (client.package / relative).lexically_normal();
  client.executable = client.desktop.parent_path() / L"resources/codex.exe";
  client.applicationId = Wide(value.at("family").get<std::string>() + "!" + value.at("id").get<std::string>());
  client.revision = FileRevision(client.desktop) + FileRevision(client.executable);
  return client;
}
bool DesktopClient::SameInstallation(const DesktopClient& other) const {
  return SamePath(package, other.package) && applicationId == other.applicationId && revision == other.revision;
}
void DesktopClient::EnsureStopped(const Cancelled& cancelled) const {
  if (cancelled && cancelled()) throw Failure(FailureCode::cancelled);
  Require(revision == FileRevision(desktop) + FileRevision(executable));
  const auto all = Processes();
  const auto selected = DesktopTree(*this, all);
  NoOtherWriters(all, selected, cancelled);
  Require(selected.empty(), FailureCode::busy);
}
void DesktopClient::Quit(const Cancelled& cancelled, bool& wasRunning) const {
  FILETIME observedAt = {}; GetSystemTimeAsFileTime(&observedAt);
  const auto all = Processes();
  const auto selected = DesktopTree(*this, all);
  NoOtherWriters(all, selected, cancelled);
  if (selected.empty()) return;
  // Pin and validate the selected process handles before terminating any of them.
  std::vector<std::unique_ptr<Handle>> handles;
  for (const auto id : selected) {
    auto handle = std::make_unique<Handle>(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
        PROCESS_TERMINATE | SYNCHRONIZE, FALSE, id));
    if (!handle->value && GetLastError() == ERROR_INVALID_PARAMETER) continue;
    Require(handle->value != nullptr && SameUser(handle->value), FailureCode::busy);
    FILETIME created = {}, exited = {}, kernel = {}, user = {};
    Require(GetProcessTimes(handle->value, &created, &exited, &kernel, &user) != FALSE &&
        CompareFileTime(&created, &observedAt) <= 0, FailureCode::busy);
    const auto entry = std::find_if(all.begin(), all.end(), [id](const auto& item) { return item.id == id; });
    Require(entry != all.end() && _wcsicmp(Image(handle->value).filename().c_str(), entry->name.c_str()) == 0,
            FailureCode::busy);
    handles.push_back(std::move(handle));
  }
  if (cancelled && cancelled()) throw Failure(FailureCode::cancelled);
  wasRunning = true;  // The caller must reopen even if termination partially fails.
  for (const auto& process : handles)
    Require(TerminateProcess(process->value, 0) || WaitForSingleObject(process->value, 0) == WAIT_OBJECT_0,
            FailureCode::busy);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(8);
  while (std::chrono::steady_clock::now() < deadline) {
    bool stopped = true;
    for (const auto& process : handles)
      if (WaitForSingleObject(process->value, 20) != WAIT_OBJECT_0) stopped = false;
    if (stopped) { EnsureStopped(cancelled); return; }
  }
  throw Failure(FailureCode::busy);
}
bool DesktopClient::Reopen() const {
  const auto com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  Microsoft::WRL::ComPtr<IApplicationActivationManager> manager;
  const auto created = CoCreateInstance(CLSID_ApplicationActivationManager, nullptr, CLSCTX_LOCAL_SERVER,
      IID_PPV_ARGS(&manager));
  DWORD pid = 0;
  const bool opened = SUCCEEDED(created) && SUCCEEDED(manager->ActivateApplication(applicationId.c_str(),
      nullptr, AO_NONE, &pid));
  manager.Reset();
  if (SUCCEEDED(com)) CoUninitialize();
  return opened;
}

void OpenOfficialAuthorization(const std::string& raw) {
  const auto url = Wide(raw);
  URL_COMPONENTS parts = {}; parts.dwStructSize = sizeof(parts);
  parts.dwHostNameLength = static_cast<DWORD>(-1);
  parts.dwUserNameLength = static_cast<DWORD>(-1);
  parts.dwPasswordLength = static_cast<DWORD>(-1);
  Require(WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &parts) != FALSE,
          FailureCode::protocolError);
  const auto host = std::wstring(parts.lpszHostName, parts.dwHostNameLength);
  Require(parts.nScheme == INTERNET_SCHEME_HTTPS && parts.nPort == 443 &&
      parts.dwUserNameLength == 0 && parts.dwPasswordLength == 0 &&
      (host == L"auth.openai.com" || host == L"chatgpt.com"), FailureCode::protocolError);
  Require(reinterpret_cast<INT_PTR>(ShellExecuteW(nullptr, L"open", url.c_str(), nullptr, nullptr, SW_SHOWNORMAL)) > 32);
}
std::filesystem::path CodexHome() {
  wchar_t* raw = nullptr;
  size_t count = 0;
  Require(_wdupenv_s(&raw, &count, L"CODEX_HOME") == 0);
  std::unique_ptr<wchar_t, decltype(&free)> configured(raw, free);
  if (raw && *raw) {
    const std::filesystem::path path(raw);
    Require(path.is_absolute() && path == path.lexically_normal());
    return path;
  }
  PWSTR profile = nullptr;
  Require(SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &profile)));
  const auto root = std::filesystem::path(profile) / L".codex";
  CoTaskMemFree(profile);
  return root;
}
}  // namespace loongpass::codex
