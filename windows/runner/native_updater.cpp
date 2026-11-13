#include "native_updater.h"
#include "loongpass_config.h"
#include "update_contract.h"
#include <flutter/standard_method_codec.h>
#include <winsparkle.h>
#include <mutex>
#include <optional>
#include <utility>

namespace loongpass {
namespace {
constexpr UINT kChanged = WM_APP + 231;
constexpr std::time_t kCheckInterval = 24 * 60 * 60;
constexpr UINT_PTR kTimer = 0x4C50;
constexpr wchar_t kSettings[] = L"Software\\SailingLoong\\LoongPass\\Updates";
std::mutex event_mutex;
HWND updater_window = nullptr;
std::optional<Json> pending_event;

bool Preference(const wchar_t* name, bool missing = false) {
  DWORD value = 0, size = sizeof(value);
  const auto status = RegGetValueW(HKEY_CURRENT_USER, kSettings, name, RRF_RT_REG_DWORD,
                                   nullptr, &value, &size);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) return missing;
  if (status != ERROR_SUCCESS) throw std::runtime_error("Preference unavailable");
  return value == 1;
}
void SavePreference(const wchar_t* name, bool value) {
  DWORD data = value ? 1 : 0;
  if (RegSetKeyValueW(HKEY_CURRENT_USER, kSettings, name, REG_DWORD, &data, sizeof(data)) != ERROR_SUCCESS)
    throw std::runtime_error("Preference unavailable");
}
void Changed(win_sparkle_inline_event event, const char* version,
             size_t downloaded, size_t total, int error) {
  // SDK callbacks run on workers: only enqueue data, never touch Flutter here.
  const char* phase = update::phases::error;
  switch (event) {
    case WIN_SPARKLE_INLINE_CHECKING: phase = update::phases::checking; break;
    case WIN_SPARKLE_INLINE_DOWNLOADING: phase = update::phases::downloading; break;
    case WIN_SPARKLE_INLINE_PREPARING: phase = update::phases::preparing; break;
    case WIN_SPARKLE_INLINE_READY: phase = update::phases::ready; break;
    case WIN_SPARKLE_INLINE_INSTALLING: phase = update::phases::installing; break;
    case WIN_SPARKLE_INLINE_UP_TO_DATE: phase = update::phases::upToDate; break;
    case WIN_SPARKLE_INLINE_ERROR: break;
  }
  Json value = {{update::phase, phase}, {update::offeredVersion, version ? version : ""},
                {update::progress, nullptr}, {update::error, ""}};
  if (event == WIN_SPARKLE_INLINE_DOWNLOADING && total > 0)
    value[update::progress] = (std::min)(1.0, static_cast<double>(downloaded) / total);
  if (event == WIN_SPARKLE_INLINE_ERROR)
    value[update::error] = error == 1 ? "更新签名校验失败，请重新检查更新。" :
                          error == 2 ? "此版本需通过官网下载，请查看 loongpass.com。" :
                                       "更新未完成，请检查网络或安装权限后重试。";
  std::lock_guard<std::mutex> lock(event_mutex);
  if (updater_window) {
    pending_event = std::move(value);
    PostMessageW(updater_window, kChanged, 0, 0);
  }
}
void Shutdown() {
  std::lock_guard<std::mutex> lock(event_mutex);
  if (updater_window) PostMessageW(updater_window, WM_CLOSE, 0, 0);
}
}  // namespace

NativeUpdater::NativeUpdater(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), automatic_(Preference(L"AutomaticUpdates", true)),
      beta_(Preference(L"ReceiveBetaUpdates")), phase_(update::phases::idle) {
  { std::lock_guard<std::mutex> lock(event_mutex); updater_window = window; }
  ULONGLONG next = 0;
  DWORD size = sizeof(next);
  if (RegGetValueW(HKEY_CURRENT_USER, kSettings, L"NextCheck", RRF_RT_REG_QWORD,
                   nullptr, &next, &size) == ERROR_SUCCESS) next_check_ = static_cast<std::time_t>(next);
  const auto version = Wide(LOONGPASS_RELEASE_NAME), build = Wide(LOONGPASS_BUILD_NUMBER);
  win_sparkle_set_app_details(L"SailingLoong", L"LoongPass", version.c_str());
  win_sparkle_set_app_build_version(build.c_str());
  win_sparkle_set_registry_path("Software\\SailingLoong\\LoongPass\\WinSparkle");
  if (!win_sparkle_set_eddsa_public_key(LOONGPASS_UPDATE_PUBLIC_KEY))
    throw std::runtime_error("Update verifier unavailable");
  win_sparkle_set_appcast_url(beta_ ? LOONGPASS_BETA_FEED : LOONGPASS_STABLE_FEED);
  // Native scheduling covers attempts even on empty/error feeds. No view starts it.
  win_sparkle_set_automatic_check_for_updates(0);
  win_sparkle_set_inline_callback(Changed);
  win_sparkle_set_shutdown_request_callback(Shutdown);
  win_sparkle_init();
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, update::channel, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const Call& call, std::unique_ptr<Result> result) {
    try {
      const auto& method = call.method_name();
      if (method == update::check) {
        if (OwnsCandidate()) { result->Error("busy"); return; }
        Check(false);
      } else if (method == update::install) {
        if (phase_ != update::phases::ready) { result->Error("busy"); return; }
        phase_ = update::phases::installing;
        Publish();
        if (!win_sparkle_install_prepared_update()) { result->Error("install_failed"); return; }
      } else if (method == update::skip) {
        if (phase_ != update::phases::ready || !win_sparkle_skip_prepared_update()) {
          result->Error("busy"); return;
        }
        phase_ = update::phases::idle; offered_version_.clear(); progress_ = nullptr;
        Publish();
      } else if (method == update::setAutomaticUpdates || method == update::setReceiveBetaUpdates) {
        const auto value = Decode(call.arguments());
        if (!value.is_boolean()) { result->Error("invalid_setting"); return; }
        if (method == update::setAutomaticUpdates) {
          SavePreference(L"AutomaticUpdates", value.get<bool>());
          automatic_ = value.get<bool>();
        } else {
          if (OwnsCandidate()) { result->Error("busy"); return; }
          SavePreference(L"ReceiveBetaUpdates", value.get<bool>());
          beta_ = value.get<bool>();
          win_sparkle_set_appcast_url(beta_ ? LOONGPASS_BETA_FEED : LOONGPASS_STABLE_FEED);
          next_check_ = 0;
        }
        Publish();
        PostMessageW(window_, WM_TIMER, kTimer, 0);
      } else if (method != update::state) { result->NotImplemented(); return; }
      result->Success(Encode(State()));
    } catch (...) { result->Error("updates_unavailable"); }
  });
  SetTimer(window_, kTimer, 60000, nullptr);
  PostMessageW(window_, WM_TIMER, kTimer, 0);
}

NativeUpdater::~NativeUpdater() {
  KillTimer(window_, kTimer);
  { std::lock_guard<std::mutex> lock(event_mutex); updater_window = nullptr; pending_event.reset(); }
  win_sparkle_cleanup(); // Joins custom-UI checker/downloader before unloading.
}

bool NativeUpdater::OwnsCandidate() const {
  return phase_ == update::phases::checking || phase_ == update::phases::downloading ||
         phase_ == update::phases::preparing || phase_ == update::phases::ready || phase_ == update::phases::installing;
}
Json NativeUpdater::State() const {
  return {{update::revision, revision_}, {update::phase, phase_},
          {update::version, std::string(LOONGPASS_RELEASE_NAME) + " (" + LOONGPASS_BUILD_NUMBER + ")"},
          {update::offeredVersion, offered_version_.empty() ? Json(nullptr) : Json(offered_version_)},
          {update::progress, progress_}, {update::error, error_.empty() ? Json(nullptr) : Json(error_)},
          {update::canCheck, !OwnsCandidate()}, {update::canChangeChannel, !OwnsCandidate()},
          {update::canInstall, phase_ == update::phases::ready}, {update::canSkip, phase_ == update::phases::ready},
          {update::automaticUpdates, automatic_}, {update::receiveBetaUpdates, beta_}, {update::installOnQuit, false}};
}
void NativeUpdater::Publish() {
  ++revision_;
  channel_->InvokeMethod(update::stateChanged, std::make_unique<Value>(Encode(State())));
}
void NativeUpdater::Check(bool automatic) {
  next_check_ = std::time(nullptr) + kCheckInterval;
  const ULONGLONG next = static_cast<ULONGLONG>(next_check_);
  if (RegSetKeyValueW(HKEY_CURRENT_USER, kSettings, L"NextCheck", REG_QWORD, &next, sizeof(next)) != ERROR_SUCCESS)
    throw std::runtime_error("Update scheduling unavailable");
  if (!win_sparkle_check_update_inline(automatic ? 0 : 1))
    throw std::runtime_error("Update check unavailable");
  phase_ = update::phases::checking; offered_version_.clear(); error_.clear(); progress_ = nullptr;
  Publish();
}
bool NativeUpdater::HandleMessage(UINT message, WPARAM parameter) {
  if (message == kChanged) {
    std::optional<Json> event;
    { std::lock_guard<std::mutex> lock(event_mutex); event.swap(pending_event); }
    if (event) {
      phase_ = (*event)[update::phase].get<std::string>();
      offered_version_ = (*event)[update::offeredVersion].get<std::string>();
      progress_ = (*event)[update::progress];
      error_ = (*event)[update::error].get<std::string>();
      Publish();
    }
    return true;
  }
  if (message == WM_TIMER && parameter == kTimer) {
    if (automatic_ && !OwnsCandidate() && std::time(nullptr) >= next_check_) {
      try { Check(true); }
      catch (...) { phase_ = update::phases::error; error_ = "暂时无法检查更新，请稍后重试。"; Publish(); }
    }
    return true;
  }
  return false;
}
}  // namespace loongpass
