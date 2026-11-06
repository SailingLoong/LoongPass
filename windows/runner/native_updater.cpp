#include "native_updater.h"
#include "loongpass_config.h"
#include <flutter/standard_method_codec.h>
#include <winsparkle.h>
#include <atomic>
#include <ctime>

namespace loongpass {
namespace {
constexpr UINT kFinished = WM_APP + 231;
constexpr WPARAM kLookupFinished = 1, kLookupFound = 2, kDialogClosed = 3;
constexpr std::time_t kCheckInterval = 24 * 60 * 60;
constexpr UINT_PTR kTimer = 0x4C50;
constexpr wchar_t kSettings[] = L"Software\\SailingLoong\\LoongPass\\Updates";
std::atomic<HWND> updater_window{nullptr};

bool Preference(const wchar_t* name) {
  DWORD value = 0;
  DWORD size = sizeof(value);
  return RegGetValueW(HKEY_CURRENT_USER, kSettings, name, RRF_RT_REG_DWORD,
                      nullptr, &value, &size) == ERROR_SUCCESS && value == 1;
}

void SavePreference(const wchar_t* name, bool value) {
  DWORD data = value ? 1 : 0;
  if (RegSetKeyValueW(HKEY_CURRENT_USER, kSettings, name, REG_DWORD,
                      &data, sizeof(data)) != ERROR_SUCCESS) {
    throw std::runtime_error("Preference unavailable");
  }
}

void Notify(WPARAM event) {
  if (auto window = updater_window.load()) PostMessageW(window, kFinished, event, 0);
}
void Finished() { Notify(kLookupFinished); }
void Found() { Notify(kLookupFound); }
void Closed() { Notify(kDialogClosed); }


void Shutdown() {
  if (auto window = updater_window.load()) PostMessageW(window, WM_CLOSE, 0, 0);
}
}  // namespace

NativeUpdater::NativeUpdater(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), automatic_(Preference(L"AutomaticUpdates")),
      beta_(Preference(L"ReceiveBetaUpdates")) {
  updater_window.store(window);
  ULONGLONG next = 0;
  DWORD size = sizeof(next);
  if (RegGetValueW(HKEY_CURRENT_USER, kSettings, L"NextCheck", RRF_RT_REG_QWORD,
                    nullptr, &next, &size) == ERROR_SUCCESS) {
    next_check_ = static_cast<std::time_t>(next);
  }
  const auto version = Wide(LOONGPASS_RELEASE_NAME);
  const auto build = Wide(LOONGPASS_BUILD_NUMBER);
  win_sparkle_set_app_details(L"SailingLoong", L"LoongPass", version.c_str());
  win_sparkle_set_app_build_version(build.c_str());
  win_sparkle_set_registry_path("Software\\SailingLoong\\LoongPass\\WinSparkle");
  if (!win_sparkle_set_eddsa_public_key(LOONGPASS_UPDATE_PUBLIC_KEY)) {
    throw std::runtime_error("Update verifier unavailable");
  }
  win_sparkle_set_appcast_url(beta_ ? LOONGPASS_BETA_FEED : LOONGPASS_STABLE_FEED);
  // The combined preference schedules WinSparkle's download-and-install API.
  // Its check-only scheduler stays disabled so the two behaviors cannot diverge.
  win_sparkle_set_automatic_check_for_updates(0);
  win_sparkle_set_error_callback(Finished);
  win_sparkle_set_did_not_find_update_callback(Finished);
  win_sparkle_set_did_find_update_callback(Found);
  win_sparkle_set_update_dismissed_callback(Closed);
  win_sparkle_set_update_cancelled_callback(Closed);
  win_sparkle_set_shutdown_request_callback(Shutdown);
  win_sparkle_init();
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.sailingloong.loongpass/updates",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const Call& call, std::unique_ptr<Result> result) {
    try {
      const auto& method = call.method_name();
      if (method == "check") {
        if (phase_ != Phase::idle) { result->Error("busy"); return; }
        Check(false);
      } else if (method == "setAutomaticUpdates" || method == "setReceiveBetaUpdates") {
        const auto value = Decode(call.arguments());
        if (!value.is_boolean()) { result->Error("invalid_setting"); return; }
        if (method == "setAutomaticUpdates") {
          SavePreference(L"AutomaticUpdates", value.get<bool>());
          automatic_ = value.get<bool>();
        } else {
          if (phase_ != Phase::idle) { result->Error("busy"); return; }
          SavePreference(L"ReceiveBetaUpdates", value.get<bool>());
          beta_ = value.get<bool>();
          win_sparkle_set_appcast_url(beta_ ? LOONGPASS_BETA_FEED : LOONGPASS_STABLE_FEED);
        }
      } else if (method != "state") {
        result->NotImplemented(); return;
      }
      result->Success(Encode(State()));
      Publish();
    } catch (...) { result->Error("updates_unavailable"); }
  });
  SetTimer(window_, kTimer, 60000, nullptr);
}

NativeUpdater::~NativeUpdater() {
  KillTimer(window_, kTimer);
  updater_window.store(nullptr);
  win_sparkle_cleanup();
}

Json NativeUpdater::State() const {
  return {{"version", std::string(LOONGPASS_RELEASE_NAME) + " (" + LOONGPASS_BUILD_NUMBER + ")"},
          {"canCheck", phase_ == Phase::idle}, {"canChangeChannel", phase_ == Phase::idle},
          {"automaticUpdates", automatic_}, {"receiveBetaUpdates", beta_},
          {"installOnQuit", false}};
}

void NativeUpdater::Publish() {
  channel_->InvokeMethod("stateChanged", std::make_unique<Value>(Encode(State())));
}

void NativeUpdater::Check(bool automatic) {
  // Schedule from every attempt, including errors and empty feeds. WinSparkle's
  // successful nonempty-feed timestamp does not cover those outcomes.
  next_check_ = std::time(nullptr) + kCheckInterval;
  ULONGLONG next = static_cast<ULONGLONG>(next_check_);
  if (RegSetKeyValueW(HKEY_CURRENT_USER, kSettings, L"NextCheck", REG_QWORD,
                      &next, sizeof(next)) != ERROR_SUCCESS) {
    throw std::runtime_error("Update scheduling unavailable");
  }
  phase_ = Phase::checking;
  Publish();
  if (automatic) win_sparkle_check_update_with_ui_and_install();
  else win_sparkle_check_update_with_ui();
}

bool NativeUpdater::HandleMessage(UINT message, WPARAM parameter) {
  if (message == kFinished) {
    if (parameter == kLookupFound) phase_ = Phase::available;
    else if (parameter == kLookupFinished || phase_ != Phase::checking) phase_ = Phase::idle;
    // Closing the checking UI does not cancel the SDK's feed request.
    Publish();
    return true;
  }
  if (message == WM_TIMER && parameter == kTimer) {
    if (automatic_ && phase_ == Phase::idle && std::time(nullptr) >= next_check_) {
      try { Check(true); }
      catch (...) { phase_ = Phase::idle; Publish(); }
    }
    return true;
  }
  return false;
}
}  // namespace loongpass
