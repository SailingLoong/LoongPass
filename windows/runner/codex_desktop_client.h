#pragma once
#include "codex_process.h"

namespace loongpass::codex {
struct DesktopClient {
  std::filesystem::path package, executable, desktop;
  std::wstring applicationId;
  std::string revision;
  static DesktopClient Installed(const Cancelled& cancelled);
  void Quit(const Cancelled& cancelled, bool& wasRunning) const;
  void EnsureStopped(const Cancelled& cancelled) const;
  bool Reopen() const;
  bool SameInstallation(const DesktopClient& other) const;
};
void OpenOfficialAuthorization(const std::string& url);
std::filesystem::path CodexHome();
}  // namespace loongpass::codex
