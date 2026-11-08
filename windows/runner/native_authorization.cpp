#include "native_authorization.h"
#include "trae_authorization.h"

#include <aclapi.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shlwapi.h>
#include <winhttp.h>
#include <WebView2.h>
#include <sddl.h>
#include <wrl.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cstring>
#include <cwctype>
#include <filesystem>
#include <regex>

namespace loongpass {
namespace {

void Require(bool value) {
  if (!value) throw std::runtime_error("Native authorization unavailable");
}

struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  ~Handle() {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
  }
};

struct RegistryKey {
  HKEY value = nullptr;
  ~RegistryKey() {
    if (value) RegCloseKey(value);
  }
};

std::wstring Lower(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return value;
}

std::wstring KnownFolder(REFKNOWNFOLDERID id) {
  PWSTR path = nullptr;
  Require(SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &path)));
  std::wstring output(path);
  CoTaskMemFree(path);
  return output;
}

std::wstring RegistryText(HKEY key, const wchar_t* name) {
  DWORD size = 0;
  const DWORD flags = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ;
  if (RegGetValueW(key, nullptr, name, flags, nullptr, nullptr, &size) !=
          ERROR_SUCCESS || size == 0 || size > 65536) return {};
  std::wstring value(size / sizeof(wchar_t), L'\0');
  if (RegGetValueW(key, nullptr, name, flags, nullptr, value.data(), &size) !=
      ERROR_SUCCESS) return {};
  while (!value.empty() && value.back() == L'\0') value.pop_back();
  return value;
}

struct InstalledClient {
  std::wstring executable;
  std::string version;
  std::string platform;
};

InstalledClient FindClient(const std::wstring& name);
Json RequestContext();
Json ReadOwnedJson(const std::wstring& path, DWORD limit);
void OpenAuthorization(HWND parent, const std::string& method, const Json& args);

InstalledClient InspectClient(const std::wstring& executable,
                               const std::wstring& name) {
  DWORD ignored = 0;
  const DWORD size = GetFileVersionInfoSizeW(executable.c_str(), &ignored);
  Require(size > 0 && size <= 1024 * 1024);
  std::vector<unsigned char> bytes(size);
  Require(GetFileVersionInfoW(executable.c_str(), 0, size, bytes.data()));
  struct Translation { WORD language, codepage; };
  Translation* translations = nullptr;
  UINT count = 0;
  Require(VerQueryValueW(bytes.data(), L"\\VarFileInfo\\Translation",
                         reinterpret_cast<void**>(&translations), &count));
  bool matched = false;
  for (UINT index = 0; index < count / sizeof(Translation); ++index) {
    wchar_t query[96];
    swprintf_s(query, L"\\StringFileInfo\\%04x%04x\\ProductName",
               translations[index].language, translations[index].codepage);
    wchar_t* product = nullptr;
    UINT length = 0;
    if (VerQueryValueW(bytes.data(), query, reinterpret_cast<void**>(&product),
                        &length) && length && Lower(product) == Lower(name)) {
      matched = true;
    }
  }
  Require(matched);
  VS_FIXEDFILEINFO* version = nullptr;
  Require(VerQueryValueW(bytes.data(), L"\\", reinterpret_cast<void**>(&version),
                         &count) && count >= sizeof(VS_FIXEDFILEINFO) &&
          version->dwSignature == 0xfeef04bd);
  const auto semantic = std::to_string(HIWORD(version->dwProductVersionMS)) + "." +
      std::to_string(LOWORD(version->dwProductVersionMS)) + "." +
      std::to_string(HIWORD(version->dwProductVersionLS));
  Handle file;
  file.value = CreateFileW(executable.c_str(), GENERIC_READ, FILE_SHARE_READ,
                           nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  Require(file.value != INVALID_HANDLE_VALUE);
  IMAGE_DOS_HEADER dos{};
  DWORD read = 0;
  Require(ReadFile(file.value, &dos, sizeof(dos), &read, nullptr) &&
          read == sizeof(dos) && dos.e_magic == IMAGE_DOS_SIGNATURE &&
          dos.e_lfanew > 0 && dos.e_lfanew < 1024 * 1024);
  LARGE_INTEGER offset;
  offset.QuadPart = dos.e_lfanew;
  Require(SetFilePointerEx(file.value, offset, nullptr, FILE_BEGIN));
  DWORD signature = 0;
  IMAGE_FILE_HEADER header{};
  Require(ReadFile(file.value, &signature, sizeof(signature), &read, nullptr) &&
          read == sizeof(signature) && signature == IMAGE_NT_SIGNATURE);
  Require(ReadFile(file.value, &header, sizeof(header), &read, nullptr) &&
          read == sizeof(header));
  std::string platform;
  switch (header.Machine) {
    case IMAGE_FILE_MACHINE_AMD64: platform = "win32-x64"; break;
    case IMAGE_FILE_MACHINE_ARM64: platform = "win32-arm64"; break;
    case IMAGE_FILE_MACHINE_I386: platform = "win32-ia32"; break;
    default: Require(false);
  }
  return {executable, semantic, platform};
}

std::wstring IconExecutable(std::wstring value) {
  if (value.empty()) return {};
  PathParseIconLocationW(value.data());
  value.resize(wcslen(value.c_str()));
  if (value.size() >= 2 && value.front() == L'"' && value.back() == L'"') {
    value = value.substr(1, value.size() - 2);
  }
  return value;
}

InstalledClient FindClient(const std::wstring& name) {
  std::vector<std::wstring> candidates;
  const auto add_directory = [&](const std::filesystem::path& directory) {
    if (!directory.empty() && directory.is_absolute()) {
      candidates.push_back((directory / (name + L".exe")).wstring());
    }
  };
  for (HKEY hive : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
    for (REGSAM view : {KEY_WOW64_64KEY, KEY_WOW64_32KEY}) {
      RegistryKey app;
      const auto app_key = L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\App Paths\\" +
                           name + L".exe";
      if (RegOpenKeyExW(hive, app_key.c_str(), 0, KEY_READ | view, &app.value) ==
          ERROR_SUCCESS) {
        candidates.push_back(IconExecutable(RegistryText(app.value, nullptr)));
      }
      RegistryKey uninstall;
      if (RegOpenKeyExW(hive,
          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall", 0,
          KEY_READ | view, &uninstall.value) != ERROR_SUCCESS) continue;
      for (DWORD index = 0; index < 16384; ++index) {
        wchar_t key_name[512];
        DWORD length = static_cast<DWORD>(std::size(key_name));
        const auto status = RegEnumKeyExW(uninstall.value, index, key_name,
                                         &length, nullptr, nullptr, nullptr,
                                         nullptr);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) continue;
        RegistryKey entry;
        if (RegOpenKeyExW(uninstall.value, key_name, 0, KEY_READ, &entry.value) !=
            ERROR_SUCCESS) continue;
        const auto display_name = Lower(RegistryText(entry.value, L"DisplayName"));
        const auto display_version = RegistryText(entry.value, L"DisplayVersion");
        if (display_name != Lower(name) &&
            (display_version.empty() ||
             display_name != Lower(name + L" " + display_version))) continue;
        const auto icon = IconExecutable(RegistryText(entry.value, L"DisplayIcon"));
        if (!icon.empty()) {
          candidates.push_back(icon);
          add_directory(std::filesystem::path(icon).parent_path());
        }
        add_directory(RegistryText(entry.value, L"InstallLocation"));
        const auto uninstall_command = RegistryText(entry.value, L"UninstallString");
        int argument_count = 0;
        LPWSTR* arguments = uninstall_command.empty() ? nullptr :
            CommandLineToArgvW(uninstall_command.c_str(), &argument_count);
        if (arguments && argument_count > 0) {
          add_directory(std::filesystem::path(arguments[0]).parent_path());
        }
        if (arguments) LocalFree(arguments);
      }
    }
  }
  for (const auto& path : candidates) {
    if (path.empty() || !std::filesystem::path(path).is_absolute()) continue;
    try { return InspectClient(path, name); }
    catch (...) { /* Try another actual installed registry entry. */ }
  }
  throw std::runtime_error("Official client not found");
}

bool IsUuid(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t index = 0; index < value.size(); ++index) {
    if (index == 8 || index == 13 || index == 18 || index == 23) {
      if (value[index] != '-') return false;
    } else if (!std::isxdigit(static_cast<unsigned char>(value[index]))) {
      return false;
    }
  }
  return true;
}

std::vector<unsigned char> CurrentUser() {
  Handle token;
  Require(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value));
  DWORD size = 0;
  GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
  Require(size > 0 && size <= 65536);
  std::vector<unsigned char> data(size);
  Require(GetTokenInformation(token.value, TokenUser, data.data(), size, &size));
  return data;
}

Json ReadOwnedJson(const std::wstring& path, DWORD limit) {
  Handle file;
  file.value = CreateFileW(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_EXISTING,
                           FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  Require(file.value != INVALID_HANDLE_VALUE);
  BY_HANDLE_FILE_INFORMATION before{}, after{};
  Require(GetFileInformationByHandle(file.value, &before) &&
          !(before.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY |
                                      FILE_ATTRIBUTE_REPARSE_POINT)) &&
          before.nFileSizeHigh == 0 && before.nFileSizeLow > 0 &&
          before.nFileSizeLow <= limit);
  PSECURITY_DESCRIPTOR security = nullptr;
  PSID owner = nullptr;
  Require(GetSecurityInfo(file.value, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                           &owner, nullptr, nullptr, nullptr, &security) ==
          ERROR_SUCCESS);
  const auto user = CurrentUser();
  const bool owned = EqualSid(owner,
      reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid) != FALSE;
  LocalFree(security);
  Require(owned);
  std::string bytes(before.nFileSizeLow, '\0');
  DWORD size = 0;
  Require(ReadFile(file.value, bytes.data(), static_cast<DWORD>(bytes.size()),
                    &size, nullptr) && size == bytes.size() &&
          GetFileInformationByHandle(file.value, &after) &&
          after.nFileSizeHigh == before.nFileSizeHigh &&
          after.nFileSizeLow == before.nFileSizeLow &&
          CompareFileTime(&before.ftLastWriteTime, &after.ftLastWriteTime) == 0);
  auto value = Json::parse(bytes);
  Require(value.is_object());
  return value;
}

std::string Timezone() {
  DYNAMIC_TIME_ZONE_INFORMATION zone{};
  Require(GetDynamicTimeZoneInformation(&zone) != TIME_ZONE_ID_INVALID &&
          zone.TimeZoneKeyName[0]);
  // Windows ships ICU. Map the Windows zone key to the IANA identifier used by
  // the official Electron client's Intl.DateTimeFormat().resolvedOptions().
  HMODULE icu = LoadLibraryExW(L"icu.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  Require(icu != nullptr);
  using MapZone = int32_t(__cdecl*)(const wchar_t*, int32_t, const char*,
                                    wchar_t*, int32_t, int32_t*);
  const auto procedure = GetProcAddress(icu, "ucal_getTimeZoneIDForWindowsID");
  MapZone map = nullptr;
  static_assert(sizeof(map) == sizeof(procedure));
  std::memcpy(&map, &procedure, sizeof(map));
  wchar_t output[256]{};
  int32_t error = 0;
  int32_t length = map ? map(zone.TimeZoneKeyName, -1, nullptr, output,
                            static_cast<int32_t>(std::size(output)), &error) : 0;
  FreeLibrary(icu);
  Require(length > 0 && length < static_cast<int32_t>(std::size(output)) && error <= 0);
  return Utf8(std::wstring(output, length));
}

Json RequestContext() {
  const auto client = FindClient(L"ZCode");
  const auto path = std::filesystem::path(KnownFolder(FOLDERID_Profile)) /
                    L".zcode" / L"v2" / L"telemetry-state.json";
  const auto telemetry = ReadOwnedJson(path.wstring(), 16384);
  auto device = telemetry.at("deviceMid").get<std::string>();
  Require(IsUuid(device));
  std::transform(device.begin(), device.end(), device.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  wchar_t locale[LOCALE_NAME_MAX_LENGTH]{};
  Require(GetUserDefaultLocaleName(locale, LOCALE_NAME_MAX_LENGTH) > 0);
  return {{"version", client.version}, {"platform", client.platform},
          {"deviceMid", device}, {"language", Lower(locale).rfind(L"zh", 0) == 0
                                               ? "zh-CN" : "en-US"},
          {"timezone", Timezone()}};
}

struct HttpsUrl {
  std::wstring raw, host, path;
  std::vector<std::pair<std::string, std::string>> query;
};

std::string QueryText(const std::string& text) {
  std::string output;
  for (size_t index = 0; index < text.size(); ++index) {
    if (text[index] == '%') {
      Require(index + 2 < text.size());
      auto digit = [](unsigned char value) {
        if (value >= '0' && value <= '9') return value - '0';
        value = static_cast<unsigned char>(std::tolower(value));
        Require(value >= 'a' && value <= 'f');
        return value - 'a' + 10;
      };
      output.push_back(static_cast<char>(digit(text[index + 1]) * 16 +
                                          digit(text[index + 2])));
      index += 2;
    } else {
      output.push_back(text[index] == '+' ? ' ' : text[index]);
    }
  }
  Wide(output);  // Reject malformed UTF-8 and embedded controls below.
  return output;
}

bool HasControls(const std::string& value) {
  const auto wide = Wide(value);
  return std::any_of(wide.begin(), wide.end(), [](wchar_t c) {
    return c < 32 || (c >= 127 && c <= 159);
  });
}

HttpsUrl ParseHttps(const std::string& raw) {
  Require(!raw.empty() && raw.size() <= 65536 && !HasControls(raw) &&
          raw.find('#') == std::string::npos);
  HttpsUrl parsed;
  parsed.raw = Wide(raw);
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwSchemeLength = parts.dwHostNameLength = parts.dwUserNameLength =
      parts.dwPasswordLength = parts.dwUrlPathLength = parts.dwExtraInfoLength =
          static_cast<DWORD>(-1);
  Require(WinHttpCrackUrl(parsed.raw.c_str(), static_cast<DWORD>(parsed.raw.size()),
                           0, &parts) && parts.nScheme == INTERNET_SCHEME_HTTPS &&
          parts.nPort == 443 && parts.dwUserNameLength == 0 &&
          parts.dwPasswordLength == 0);
  parsed.host = Lower(std::wstring(parts.lpszHostName, parts.dwHostNameLength));
  if (parts.dwUrlPathLength) {
    parsed.path.assign(parts.lpszUrlPath, parts.dwUrlPathLength);
  }
  std::string query;
  if (parts.dwExtraInfoLength) {
    query = Utf8(std::wstring(parts.lpszExtraInfo, parts.dwExtraInfoLength));
  }
  if (!query.empty()) Require(query.front() == '?');
  size_t offset = query.empty() ? 0 : 1;
  while (offset < query.size()) {
    const auto end = query.find('&', offset);
    const auto part = query.substr(offset, end == std::string::npos
                                             ? end : end - offset);
    const auto equal = part.find('=');
    parsed.query.emplace_back(QueryText(part.substr(0, equal)),
        equal == std::string::npos ? "" : QueryText(part.substr(equal + 1)));
    if (end == std::string::npos) break;
    offset = end + 1;
  }
  return parsed;
}

void OpenAuthorization(HWND parent, const std::string& method, const Json& args) {
  const auto raw = args.at("url").get<std::string>();
  const auto url = ParseHttps(raw);
  bool allowed = false;
  bool token = false, password = false, verifier = false, device_code = false;
  int state_count = 0;
  bool state_valid = false;
  for (const auto& item : url.query) {
    const auto name = Utf8(Lower(Wide(item.first)));
    token |= name.find("token") != std::string::npos;
    password |= name.find("password") != std::string::npos;
    verifier |= name == "code_verifier";
    device_code |= name == "device_code";
    if (item.first == "state") {
      ++state_count;
      const auto state = Wide(item.second);
      state_valid = item.second.size() <= 4096 && !HasControls(item.second) &&
          std::any_of(state.begin(), state.end(),
                       [](wchar_t c) { return !std::iswspace(c); });
    }
  }
  if (method == "openWorkBuddyAuthorization" ||
      method == "openWorkBuddyIdentityAuthorization") {
    allowed = raw.size() <= 16384 &&
        (url.host == L"www.codebuddy.cn" || url.host == L"www.workbuddy.cn") &&
        state_count == 1 && state_valid && !token && !password;
  } else if (method == "openMiniMaxAuthorization") {
    const auto region = args.at("region").get<std::string>();
    const std::vector<std::wstring> hosts = region == "cn"
        ? std::vector<std::wstring>{L"account.minimax.cn", L"agent.minimaxi.com",
                                    L"agent.minimax.cn", L"code.minimax.cn"}
        : region == "global"
        ? std::vector<std::wstring>{L"account.minimax.io", L"agent.minimax.io",
                                    L"code.minimax.io"}
        : std::vector<std::wstring>{};
    allowed = std::find(hosts.begin(), hosts.end(), url.host) != hosts.end() &&
              !token && !verifier && !device_code;
  } else if (method == "openQoderAuthorization") {
    const auto region = args.at("region").get<std::string>();
    allowed = url.path == L"/device/selectAccounts" &&
        ((region == "cn" && url.host == L"qoder.cn") ||
         (region == "global" && url.host == L"qoder.com"));
  } else if (method == "openTraeAuthorization") {
    allowed = url.host == L"www.trae.cn" && url.path == L"/authorization" &&
              !token && !verifier;
  } else if (method == "openZcodeAuthorization") {
    allowed = (url.host == L"bigmodel.cn" && url.path == L"/login") ||
        (url.host == L"zcode.z.ai" &&
         (url.path == L"/authorize" || url.path == L"/oauth/authorize"));
  }
  Require(allowed);
  SHELLEXECUTEINFOW execute{};
  execute.cbSize = sizeof(execute);
  execute.fMask = SEE_MASK_FLAG_NO_UI;
  execute.hwnd = parent;
  execute.lpVerb = L"open";
  execute.lpFile = url.raw.c_str();
  execute.nShow = SW_SHOWNORMAL;
  if (!ShellExecuteExW(&execute)) throw std::runtime_error("BrowserUnavailable");
}

Json WindowsDeviceFacts() {
  wchar_t computer[256]{};
  DWORD count = static_cast<DWORD>(std::size(computer));
  Require(GetComputerNameW(computer, &count));
  auto system_value = [](const wchar_t* path, const wchar_t* name) {
    RegistryKey key;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, path, 0,
                      KEY_READ | KEY_WOW64_64KEY, &key.value) != ERROR_SUCCESS) {
      return std::string();
    }
    return Utf8(RegistryText(key.value, name));
  };
  OSVERSIONINFOW version{};
  version.dwOSVersionInfoSize = sizeof(version);
  using ReadVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
  const auto procedure = GetProcAddress(GetModuleHandleW(L"ntdll.dll"),
                                       "RtlGetVersion");
  ReadVersion read_version = nullptr;
  static_assert(sizeof(read_version) == sizeof(procedure));
  std::memcpy(&read_version, &procedure, sizeof(read_version));
  Require(read_version && read_version(&version) == 0);
  return {{"DeviceName", Utf8(std::wstring(computer, count))},
          {"DeviceModel", system_value(L"HARDWARE\\DESCRIPTION\\System\\BIOS",
                                        L"SystemProductName")},
          {"DeviceBrand", system_value(L"HARDWARE\\DESCRIPTION\\System\\BIOS",
                                        L"SystemManufacturer")},
          {"DeviceCPU", system_value(
              L"HARDWARE\\DESCRIPTION\\System\\CentralProcessor\\0",
              L"ProcessorNameString")},
          {"OSInfo", "Windows"},
          {"OSVersion", std::to_string(version.dwMajorVersion) + "." +
              std::to_string(version.dwMinorVersion) + "." +
              std::to_string(version.dwBuildNumber)}};
}

Json ChooseTraeAuthorization(HWND parent) {
  wchar_t selected[32768]{};
  const auto initial = std::filesystem::path(KnownFolder(FOLDERID_RoamingAppData)) /
                       L"Trae CN" / L"User" / L"globalStorage";
  const auto directory = initial.wstring();
  OPENFILENAMEW picker{};
  picker.lStructSize = sizeof(picker);
  picker.hwndOwner = parent;
  picker.lpstrFilter = L"TRAE CN storage.json\0*.json\0All files\0*.*\0\0";
  picker.lpstrFile = selected;
  picker.nMaxFile = static_cast<DWORD>(std::size(selected));
  picker.lpstrInitialDir = directory.c_str();
  picker.lpstrTitle = L"Read TRAE CN current authorization";
  picker.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR |
                 OFN_EXPLORER | OFN_DONTADDTORECENT | OFN_NODEREFERENCELINKS;
  if (!GetOpenFileNameW(&picker)) {
    Require(CommDlgExtendedError() == 0);
    return nullptr;
  }
  const auto source = ReadOwnedJson(selected, 8 * 1024 * 1024);
  const auto client = FindClient(L"Trae CN");
  return DecodeTraeAuthorization(source, client.version, WindowsDeviceFacts());
}

std::string CaptchaPage(const Json& configuration) {
  return R"HTML(<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' https://*.alicdn.com; style-src 'unsafe-inline' https://*.alicdn.com; font-src data:; img-src data: blob: https://*.alicdn.com https://*.aliyuncs.com; connect-src https://*.alicdn.com https://*.aliyuncs.com; frame-src https://*.alicdn.com https://*.aliyuncs.com; worker-src blob:; base-uri 'none'; form-action 'none'">
<style>body{font:16px 'Segoe UI',sans-serif;padding:28px;color:#202124;background:#f7f8fa}button{font:inherit;border:0;border-radius:8px;padding:12px 20px;margin:8px 8px 8px 0;cursor:pointer}p{line-height:1.6}</style></head>
<body><h2>ZCode 活动验证</h2><p id="status">正在辅助完成官方安全验证…</p>
<div id="captcha"></div><button id="verify" hidden>继续验证</button><button id="cancel">取消</button>
<script>
const config=)HTML" + configuration.dump() + R"HTML(,status=document.getElementById('status');
let submitted=false,shown=false,startTimer,fallbackTimer;
const post=body=>window.chrome.webview.postMessage(body);
const finish=body=>{if(submitted)return;submitted=true;clearTimeout(startTimer);clearTimeout(fallbackTimer);post(body);};
const interactive=()=>{
  if(submitted||shown)return;shown=true;clearTimeout(fallbackTimer);
  status.textContent='请继续完成下方官方验证。通过后会核对并领取。';
  document.getElementById('verify').hidden=false;post({type:'interactive'});
};
document.getElementById('cancel').onclick=()=>finish({type:'cancel'});
const run=async()=>{
  try{
    window.AliyunCaptchaConfig={region:config.region,prefix:config.prefix};
    await new Promise((resolve,reject)=>{const script=document.createElement('script');script.src='https://o.alicdn.com/captcha-frontend/aliyunCaptcha/AliyunCaptcha.js';script.onload=resolve;script.onerror=reject;document.head.appendChild(script);});
    if(submitted)return;
    window.initAliyunCaptcha({SceneId:config.sceneId,mode:'popup',language:'zh-CN',showErrorTip:false,element:'#captcha',button:'#verify',
      getInstance:instance=>{
        if(submitted)return;
        if(typeof instance.startTracelessVerification==='function'){
          startTimer=setTimeout(()=>{
            if(submitted||shown)return;
            fallbackTimer=setTimeout(()=>finish({type:'unavailable'}),12000);
            try{instance.startTracelessVerification();}catch{finish({type:'unavailable'});}
          },2200);
        }else{interactive();instance.show?.();}
      },
      success:value=>{const param=typeof value==='string'?value:value?.captchaVerifyParam;if(param)finish({type:'proof',param});},
      fail:interactive,onError:()=>finish({type:'unavailable'}),
      onClose:reason=>{if(reason==='userDismiss')finish({type:'cancel'});}});
  }catch{finish({type:'unavailable'});}
};
void run();
</script></body></html>)HTML";
}

std::wstring PrivateVerificationDirectory() {
  wchar_t temporary[32768]{};
  const auto length = GetTempPathW(static_cast<DWORD>(std::size(temporary)), temporary);
  Require(length > 0 && length < std::size(temporary));
  const auto user = CurrentUser();
  LPWSTR sid = nullptr;
  Require(ConvertSidToStringSidW(
      reinterpret_cast<const TOKEN_USER*>(user.data())->User.Sid, &sid));
  const auto policy = std::wstring(L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;") + sid + L")";
  LocalFree(sid);
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  Require(ConvertStringSecurityDescriptorToSecurityDescriptorW(policy.c_str(),
      SDDL_REVISION_1, &descriptor, nullptr));
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
  const auto path = std::filesystem::path(temporary) /
                    (L"LoongPass-ZCode-" + Wide(RandomHex(16)));
  const BOOL created = CreateDirectoryW(path.c_str(), &security);
  LocalFree(descriptor);
  Require(created != FALSE);
  return path.wstring();
}

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

bool RemoveVerificationDirectory(const std::wstring& path) {
  if (path.empty()) return true;
  std::error_code error;
  std::filesystem::remove_all(std::filesystem::path(path), error);
  return !error;
}

// Keep the environment alive until all its browser processes release the fresh
// profile. Removing a WebView2 profile while its processes run is unsupported.
void CleanupAfterBrowserExit(ICoreWebView2Environment* environment,
                             const std::wstring& path) {
  struct Cleanup {
    ComPtr<ICoreWebView2Environment5> environment;
    EventRegistrationToken token{};
    std::wstring path;
  };
  auto cleanup = std::make_shared<Cleanup>();
  Require(SUCCEEDED(environment->QueryInterface(IID_PPV_ARGS(&cleanup->environment))));
  cleanup->path = path;
  Require(SUCCEEDED(cleanup->environment->add_BrowserProcessExited(
      Callback<ICoreWebView2BrowserProcessExitedEventHandler>(
          [cleanup](ICoreWebView2Environment*,
                    ICoreWebView2BrowserProcessExitedEventArgs*) -> HRESULT {
            cleanup->environment->remove_BrowserProcessExited(cleanup->token);
            cleanup->environment.Reset();
            RemoveVerificationDirectory(cleanup->path);
            return S_OK;
          }).Get(), &cleanup->token)));
}

class CaptchaWindow : public std::enable_shared_from_this<CaptchaWindow> {
 public:
  CaptchaWindow(HWND parent, Json configuration, std::unique_ptr<Result> result)
      : parent_(parent), page_(CaptchaPage(configuration)), result_(std::move(result)) {}
  ~CaptchaWindow() { RemoveVerificationDirectory(profile_); }
  void Start();
  void Finish(const Json& proof = nullptr, bool unavailable = false);
  bool finished() const { return !result_; }

 private:
  static LRESULT CALLBACK WindowProcedure(HWND window, UINT message,
                                           WPARAM wparam, LPARAM lparam);
  HRESULT EnvironmentCreated(HRESULT error, ICoreWebView2Environment* environment);
  HRESULT ControllerCreated(HRESULT error, ICoreWebView2Controller* controller);
  void RegisterEvents();
  void Message(ICoreWebView2WebMessageReceivedEventArgs* args);
  void CloseWebView();
  void Resize();
  HWND parent_;
  HWND window_ = nullptr;
  std::string page_;
  std::wstring profile_;
  std::unique_ptr<Result> result_;
  bool initializing_ = false;
  bool modal_ = false;
  ComPtr<ICoreWebView2Environment> environment_;
  ComPtr<ICoreWebView2Controller> controller_;
  ComPtr<ICoreWebView2> web_;
};

void CaptchaWindow::Start() {
  WNDCLASSW type{};
  type.lpfnWndProc = WindowProcedure;
  type.hInstance = GetModuleHandleW(nullptr);
  type.lpszClassName = L"LoongPassZcodeVerification";
  type.hCursor = LoadCursor(nullptr, IDC_ARROW);
  Require(RegisterClassW(&type) || GetLastError() == ERROR_CLASS_ALREADY_EXISTS);
  RECT parent{};
  Require(GetWindowRect(parent_, &parent));
  window_ = CreateWindowExW(WS_EX_DLGMODALFRAME, type.lpszClassName,
      L"ZCode verification", WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU,
      parent.left + ((parent.right - parent.left) - 580) / 2,
      parent.top + ((parent.bottom - parent.top) - 460) / 2,
      580, 460, parent_, nullptr, type.hInstance, this);
  Require(window_ != nullptr);
  Require(SetTimer(window_, 1, 120000, nullptr) != 0);
  profile_ = PrivateVerificationDirectory();
  initializing_ = true;
  const auto self = shared_from_this();
  const HRESULT started = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, profile_.c_str(), nullptr,
      Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [self](HRESULT error, ICoreWebView2Environment* environment) {
            return self->EnvironmentCreated(error, environment);
          }).Get());
  if (FAILED(started)) {
    initializing_ = false;
    Finish(nullptr, true);
  }
}

LRESULT CALLBACK CaptchaWindow::WindowProcedure(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam) {
  auto* self = reinterpret_cast<CaptchaWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    self = static_cast<CaptchaWindow*>(
        reinterpret_cast<CREATESTRUCTW*>(lparam)->lpCreateParams);
    SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
    self->window_ = window;
  }
  if (self) {
    if (message == WM_CLOSE || message == WM_TIMER || message == WM_DESTROY) {
      const auto keep_alive = self->shared_from_this();
      self->Finish();
      return 0;
    }
    if (message == WM_SIZE) self->Resize();
    if (message == WM_NCDESTROY) {
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      self->window_ = nullptr;
    }
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void CaptchaWindow::Resize() {
  if (!window_ || !controller_) return;
  RECT bounds{};
  if (GetClientRect(window_, &bounds)) controller_->put_Bounds(bounds);
}

HRESULT CaptchaWindow::EnvironmentCreated(
    HRESULT error, ICoreWebView2Environment* environment) {
  if (FAILED(error) || !environment || finished()) {
    initializing_ = false;
    Finish();
    CloseWebView();
    return S_OK;
  }
  environment_ = environment;
  try {
    ComPtr<ICoreWebView2Environment10> environment10;
    Require(SUCCEEDED(environment_.As(&environment10)));
    ComPtr<ICoreWebView2ControllerOptions> options;
    Require(SUCCEEDED(environment10->CreateCoreWebView2ControllerOptions(&options)));
    Require(SUCCEEDED(options->put_IsInPrivateModeEnabled(TRUE)));
    const auto self = shared_from_this();
    const HRESULT started = environment10->CreateCoreWebView2ControllerWithOptions(
        window_, options.Get(),
        Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [self](HRESULT status, ICoreWebView2Controller* controller) {
              return self->ControllerCreated(status, controller);
            }).Get());
    if (FAILED(started)) {
      initializing_ = false;
      Finish();
    }
  } catch (...) {
    initializing_ = false;
    Finish();
  }
  return S_OK;
}

HRESULT CaptchaWindow::ControllerCreated(
    HRESULT error, ICoreWebView2Controller* controller) {
  initializing_ = false;
  if (controller) controller_ = controller;
  if (FAILED(error) || !controller || finished()) {
    Finish();
    CloseWebView();
    return S_OK;
  }
  try {
    Require(SUCCEEDED(controller_->get_CoreWebView2(&web_)));
    ComPtr<ICoreWebView2Settings> settings;
    Require(SUCCEEDED(web_->get_Settings(&settings)));
    Require(SUCCEEDED(settings->put_AreDevToolsEnabled(FALSE)));
    Require(SUCCEEDED(settings->put_AreDefaultContextMenusEnabled(FALSE)));
    Require(SUCCEEDED(settings->put_IsStatusBarEnabled(FALSE)));
    Require(SUCCEEDED(settings->put_IsWebMessageEnabled(TRUE)));
    RegisterEvents();
    Resize();
    Require(SUCCEEDED(web_->Navigate(L"https://zcode.z.ai/")));
  } catch (...) { Finish(); }
  return S_OK;
}

void CaptchaWindow::CloseWebView() {
  if (initializing_) return;
  bool cleanup_registered = false;
  if (controller_ && environment_) {
    try {
      CleanupAfterBrowserExit(environment_.Get(), profile_);
      cleanup_registered = true;
    } catch (...) { /* Retain the path for cleanup after COM handles close. */ }
    controller_->Close();
  }
  web_.Reset();
  controller_.Reset();
  environment_.Reset();
  if (cleanup_registered || RemoveVerificationDirectory(profile_)) profile_.clear();
}

bool AllowsCaptchaNavigation(const std::string& raw, bool main_frame) {
  if (raw == "about:blank") return true;
  if (main_frame) return raw == "https://zcode.z.ai/";
  try {
    const auto url = ParseHttps(raw.substr(0, raw.find('#')));
    const auto suffix = [](const std::wstring& host, const std::wstring& value) {
      return host.size() > value.size() &&
             host.compare(host.size() - value.size(), value.size(), value) == 0;
    };
    return suffix(url.host, L".alicdn.com") || suffix(url.host, L".aliyuncs.com");
  } catch (...) { return false; }
}

void CaptchaWindow::Message(ICoreWebView2WebMessageReceivedEventArgs* args) {
  LPWSTR source = nullptr;
  if (FAILED(args->get_Source(&source))) return;
  const bool trusted = source && std::wstring(source) == L"https://zcode.z.ai/";
  CoTaskMemFree(source);
  if (!trusted || finished()) return;
  LPWSTR encoded = nullptr;
  if (FAILED(args->get_WebMessageAsJson(&encoded))) return;
  Json body;
  try { body = Json::parse(Utf8(encoded ? encoded : L"")); }
  catch (...) { CoTaskMemFree(encoded); return; }
  CoTaskMemFree(encoded);
  try {
    if (!body.is_object()) return;
    const auto type = body.at("type").get<std::string>();
    if (type == "cancel" || type == "unavailable") { Finish(); return; }
    if (type == "interactive") {
      if (!window_ || !IsWindow(parent_)) { Finish(); return; }
      if (!modal_) {
        modal_ = true;
        EnableWindow(parent_, FALSE);
        ShowWindow(window_, SW_SHOWNORMAL);
        SetForegroundWindow(window_);
      }
      return;
    }
    if (type != "proof") return;
    const auto proof = body.at("param").get<std::string>();
    if (proof.empty() || proof.size() > 16384 || HasControls(proof)) return;
    Finish(proof);
  } catch (...) { /* Discard malformed messages without exposing their contents. */ }
}

void CaptchaWindow::Finish(const Json& proof, bool unavailable) {
  if (finished()) return;
  auto result = std::move(result_);
  if (window_) {
    KillTimer(window_, 1);
    DestroyWindow(window_);
    window_ = nullptr;
  }
  if (modal_ && IsWindow(parent_)) {
    EnableWindow(parent_, TRUE);
    SetForegroundWindow(parent_);
  }
  modal_ = false;
  CloseWebView();
  if (unavailable) result->Error("verification_unavailable");
  else result->Success(Encode(proof));
}

void CaptchaWindow::RegisterEvents() {
  const std::weak_ptr<CaptchaWindow> weak = shared_from_this();
  EventRegistrationToken token{};
  Require(SUCCEEDED(web_->add_NavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            LPWSTR uri = nullptr;
            BOOL initiated = FALSE;
            bool allowed = false;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri &&
                SUCCEEDED(args->get_IsUserInitiated(&initiated))) {
              allowed = !initiated && AllowsCaptchaNavigation(Utf8(uri), true);
            }
            CoTaskMemFree(uri);
            return args->put_Cancel(!allowed);
          }).Get(), &token)));
  Require(SUCCEEDED(web_->add_FrameNavigationStarting(
      Callback<ICoreWebView2NavigationStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args) -> HRESULT {
            LPWSTR uri = nullptr;
            BOOL initiated = FALSE;
            bool allowed = false;
            if (SUCCEEDED(args->get_Uri(&uri)) && uri &&
                SUCCEEDED(args->get_IsUserInitiated(&initiated))) {
              allowed = !initiated && AllowsCaptchaNavigation(Utf8(uri), false);
            }
            CoTaskMemFree(uri);
            return args->put_Cancel(!allowed);
          }).Get(), &token)));
  Require(SUCCEEDED(web_->add_NewWindowRequested(
      Callback<ICoreWebView2NewWindowRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2NewWindowRequestedEventArgs* args) -> HRESULT {
            return args->put_Handled(TRUE);
          }).Get(), &token)));
  Require(SUCCEEDED(web_->add_PermissionRequested(
      Callback<ICoreWebView2PermissionRequestedEventHandler>(
          [](ICoreWebView2*, ICoreWebView2PermissionRequestedEventArgs* args) -> HRESULT {
            return args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY);
          }).Get(), &token)));
  Require(SUCCEEDED(web_->add_WebMessageReceived(
      Callback<ICoreWebView2WebMessageReceivedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args) -> HRESULT {
            if (auto self = weak.lock()) self->Message(args);
            return S_OK;
          }).Get(), &token)));
  Require(SUCCEEDED(web_->add_ProcessFailed(
      Callback<ICoreWebView2ProcessFailedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2ProcessFailedEventArgs*) -> HRESULT {
            if (auto self = weak.lock()) self->Finish();
            return S_OK;
          }).Get(), &token)));
  ComPtr<ICoreWebView2_4> downloads;
  Require(SUCCEEDED(web_.As(&downloads)));
  Require(SUCCEEDED(downloads->add_DownloadStarting(
      Callback<ICoreWebView2DownloadStartingEventHandler>(
          [](ICoreWebView2*, ICoreWebView2DownloadStartingEventArgs* args) -> HRESULT {
            return args->put_Cancel(TRUE);
          }).Get(), &token)));
  Require(SUCCEEDED(web_->AddWebResourceRequestedFilter(
      L"https://zcode.z.ai/", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_DOCUMENT)));
  Require(SUCCEEDED(web_->add_WebResourceRequested(
      Callback<ICoreWebView2WebResourceRequestedEventHandler>(
          [weak](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
            auto self = weak.lock();
            if (!self || self->finished()) return E_ABORT;
            ComPtr<IStream> stream;
            stream.Attach(SHCreateMemStream(
                reinterpret_cast<const BYTE*>(self->page_.data()),
                static_cast<UINT>(self->page_.size())));
            ComPtr<ICoreWebView2WebResourceResponse> response;
            if (!stream) { self->Finish(); return E_ABORT; }
            const HRESULT created = self->environment_->CreateWebResourceResponse(
                stream.Get(), 200, L"OK",
                L"Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store",
                &response);
            if (FAILED(created)) { self->Finish(); return created; }
            return args->put_Response(response.Get());
          }).Get(), &token)));
}

}  // namespace

struct NativeAuthorization::State {
  explicit State(HWND window) : parent(window) {}
  HWND parent;
  bool picker_open = false;
  std::shared_ptr<CaptchaWindow> captcha;
};

NativeAuthorization::NativeAuthorization(HWND parent)
    : state_(std::make_unique<State>(parent)) {}
NativeAuthorization::~NativeAuthorization() {
  if (state_->captcha) state_->captcha->Finish();
}

bool NativeAuthorization::Handle(const Call& call,
                                  std::unique_ptr<Result>& result) {
  const auto& method = call.method_name();
  if (method == "verifyZcodeClaim") {
    if (state_->captcha && !state_->captcha->finished()) {
      result->Error("verification_unavailable");
      return true;
    }
    try {
      const auto args = Decode(call.arguments());
      Json configuration = Json::object();
      static const std::regex field("^[a-zA-Z0-9._-]{1,128}$");
      for (const auto* name : {"region", "prefix", "sceneId"}) {
        const auto value = args.at(name).get<std::string>();
        Require(std::regex_match(value, field));
        configuration[name] = value;
      }
      state_->captcha = std::make_shared<CaptchaWindow>(
          state_->parent, configuration, std::move(result));
      state_->captcha->Start();
    } catch (...) {
      if (result) result->Error("verification_unavailable");
      else if (state_->captcha) state_->captcha->Finish(nullptr, true);
    }
    return true;
  }
  if (method == "chooseTraeAuthorization") {
    if (state_->picker_open) { result->Error("ImportBusy"); return true; }
    state_->picker_open = true;
    try { result->Success(Encode(ChooseTraeAuthorization(state_->parent))); }
    catch (...) { result->Error("trae_source_unavailable"); }
    state_->picker_open = false;
    return true;
  }
  if (method == "signTraeRefresh") {
    try {
      const auto args = Decode(call.arguments());
      result->Success(Encode(SignTraeRefresh(
          args.at("privateKeyPEM").get<std::string>(),
          args.at("refreshToken").get<std::string>())));
    } catch (...) { result->Error("trae_device_unavailable"); }
    return true;
  }
  if (method == "zcodeRequestContext") {
    try { result->Success(Encode(RequestContext())); }
    catch (...) { result->Error("device_required"); }
    return true;
  }
  const std::array<const char*, 6> methods = {
      "openWorkBuddyAuthorization", "openWorkBuddyIdentityAuthorization",
      "openMiniMaxAuthorization", "openQoderAuthorization",
      "openTraeAuthorization", "openZcodeAuthorization"};
  if (std::find(methods.begin(), methods.end(), method) == methods.end()) return false;
  try {
    const auto args = Decode(call.arguments());
    OpenAuthorization(state_->parent, method, args);
    result->Success();
  } catch (const std::exception& failure) {
    if (method == "openZcodeAuthorization") {
      result->Error("authorization_unavailable");
    } else {
      result->Error(std::string(failure.what()) == "BrowserUnavailable"
                        ? "BrowserUnavailable" : "InvalidAuthorizationURL");
    }
  } catch (...) {
    result->Error("InvalidAuthorizationURL");
  }
  return true;
}

}  // namespace loongpass
