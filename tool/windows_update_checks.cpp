// Actual pinned WinSparkle DLL, synthetic signed feed and isolated registry only.
#include <windows.h>
#include <winsparkle.h>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <stdexcept>
#include <string>

namespace {
std::mutex mutex;
std::condition_variable changed;
std::deque<std::pair<win_sparkle_inline_event, int>> events;
int installs = 0, shutdowns = 0;
void Require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
void Callback(win_sparkle_inline_event event, const char*, size_t, size_t, int error) {
  { std::lock_guard<std::mutex> lock(mutex); events.emplace_back(event, error); }
  changed.notify_one();
}
void Shutdown() { ++shutdowns; }
int Installer(const wchar_t* path) {
  std::ifstream file{std::filesystem::path(path), std::ios::binary};
  if (!file.good()) return WINSPARKLE_RETURN_ERROR;
  ++installs;
  return 1; // Record the SDK action; NEVER execute an installer in this fixture.
}
int Wait(win_sparkle_inline_event wanted) {
  std::unique_lock<std::mutex> lock(mutex);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
  for (;;) {
    while (!events.empty()) {
      const auto event = events.front(); events.pop_front();
      if (event.first == wanted) return event.second;
      Require(event.first != WIN_SPARKLE_INLINE_ERROR, "Unexpected SDK error");
      Require(event.first != WIN_SPARKLE_INLINE_READY || wanted == WIN_SPARKLE_INLINE_READY,
              "A failed verification published ready");
    }
    Require(changed.wait_until(lock, deadline) != std::cv_status::timeout, "SDK event timeout");
  }
}
std::filesystem::path TemporaryPayload(const std::wstring& registry) {
  wchar_t value[32768] = {};
  DWORD size = sizeof(value);
  if (RegGetValueW(HKEY_CURRENT_USER, registry.c_str(), L"UpdateTempDir", RRF_RT_REG_SZ,
                  nullptr, value, &size) != ERROR_SUCCESS) return {};
  std::filesystem::path path(value);
  Require(std::filesystem::equivalent(path.parent_path(), std::filesystem::temp_directory_path()), "Unexpected SDK temporary parent");
  Require(path.filename().wstring().find(L"Update-") == 0, "Unexpected SDK temporary name");
  return path;
}
BOOL CALLBACK Window(HWND window, LPARAM parameter) {
  DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
  if (pid == GetCurrentProcessId()) *reinterpret_cast<bool*>(parameter) = true;
  return TRUE;
}
}
int main(int count, char** arguments) {
  if (count != 5) return 2;
  const std::string mode = arguments[1];
  const std::string registry = std::string("Software\\LoongPass\\UpdateFixture\\") + arguments[4];
  const std::wstring wide_registry(registry.begin(), registry.end());
  bool initialized = false;
  int result = 0;
  try {
    win_sparkle_set_app_details(L"LoongPassFixture", L"InlineUpdater", L"1.0.0");
    win_sparkle_set_app_build_version(L"1");
    win_sparkle_set_registry_path(registry.c_str());
    Require(win_sparkle_set_eddsa_public_key(arguments[3]) != 0, "Fixture public key rejected");
    win_sparkle_set_appcast_url(arguments[2]);
    win_sparkle_set_automatic_check_for_updates(0);
    win_sparkle_set_inline_callback(Callback);
    win_sparkle_set_shutdown_request_callback(Shutdown);
    win_sparkle_set_user_run_installer_callback(Installer);
    win_sparkle_init(); initialized = true;
    Require(win_sparkle_check_update_inline(1) == 1, "Explicit check not started");
    if (mode == "bad-signature") {
      Require(Wait(WIN_SPARKLE_INLINE_ERROR) == 1, "Signature failure not reported");
      Require(win_sparkle_install_prepared_update() == 0, "Invalid update installed");
    } else if (mode == "no-update") {
      Wait(WIN_SPARKLE_INLINE_UP_TO_DATE);
      Require(win_sparkle_install_prepared_update() == 0, "Missing update installed");
    } else {
      Wait(WIN_SPARKLE_INLINE_READY);
      Require(installs == 0 && shutdowns == 0, "Pre-download installed or quit the host");
      Require(win_sparkle_check_update_inline(1) == 0, "Prepared update checked/downloaded again");
      if (mode == "skip") {
        Require(win_sparkle_skip_prepared_update() == 1, "Prepared skip failed");
        Require(win_sparkle_install_prepared_update() == 0, "Skipped update installed");
        Require(win_sparkle_check_update_inline(0) == 1, "Automatic recheck failed");
        Wait(WIN_SPARKLE_INLINE_UP_TO_DATE);
        Require(win_sparkle_check_update_inline(1) == 1, "Manual recheck failed");
        Wait(WIN_SPARKLE_INLINE_READY); // Explicit checks retain the SDK's skip override.
      }
      if (mode == "tampered") {
        const auto folder = TemporaryPayload(wide_registry);
        Require(!folder.empty(), "No prepared SDK payload directory");
        for (const auto& entry : std::filesystem::directory_iterator(folder))
          if (entry.is_regular_file()) { std::ofstream file(entry.path(), std::ios::binary | std::ios::app); file << "tampered"; }
        Require(win_sparkle_install_prepared_update() == 0, "Tampered staged file installed");
        Require(Wait(WIN_SPARKLE_INLINE_ERROR) == 1, "Prepared payload not reverified");
      } else {
        Require(win_sparkle_install_prepared_update() == 1, "Prepared install failed");
        Require(installs == 1 && shutdowns == 1, "Native install/shutdown did not occur exactly once");
        Require(win_sparkle_install_prepared_update() == 0, "Repeated install accepted");
      }
    }
    if (mode == "bad-signature" || mode == "tampered" || mode == "no-update")
      Require(installs == 0 && shutdowns == 0, "Unsafe installer/shutdown action");
    bool window = false; EnumWindows(Window, reinterpret_cast<LPARAM>(&window));
    Require(!window, "Custom UI mode opened an updater window");
  } catch (const std::exception& error) { std::cerr << error.what() << '\n'; result = 1; }
  if (initialized) win_sparkle_cleanup();
  // Only this invocation's SDK folder and GUID registry key are removed.
  const auto folder = TemporaryPayload(wide_registry);
  if (!folder.empty()) std::filesystem::remove_all(folder);
  RegDeleteTreeA(HKEY_CURRENT_USER, registry.c_str());
  if (result == 0) std::cout << "WinSparkle integration passed: " << mode << '\n';
  return result;
}
