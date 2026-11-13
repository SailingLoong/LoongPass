// LoongPass integration only. Original WinSparkle check/download/install owns policy.
#pragma once
#include "winsparkle.h"
namespace winsparkle {
void InlineSetCallback(win_sparkle_inline_callback_t callback);
bool InlineCheck(bool manual);
bool InlineInstall();
bool InlineSkip();
void InlineShutdown();
bool InlineNoUpdates();
bool InlineAvailable(const Appcast& info);
bool InlineProgress(size_t downloaded, size_t total);
void InlinePreparing();
bool InlineDownloaded(const std::wstring& file, const Appcast& info);
bool InlineError(ErrorCode error);
}
