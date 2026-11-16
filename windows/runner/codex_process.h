#pragma once

#include "codex_account_state.h"
#include <filesystem>
#include <functional>
#include <memory>
#include <chrono>

namespace loongpass::codex {
using Cancelled = std::function<bool()>;
using Deadline = std::chrono::steady_clock::time_point;
std::wstring QuoteArgument(const std::wstring& value);

// Single-worker stdio child. Its job owns only processes created by this object.
// Handles are explicitly inherited; stderr and protocol bodies are never logged.
class StdioProcess {
 public:
  StdioProcess(const std::filesystem::path& executable,
               const std::vector<std::wstring>& arguments,
               const std::optional<std::filesystem::path>& home = std::nullopt);
  ~StdioProcess();
  StdioProcess(const StdioProcess&) = delete;
  StdioProcess& operator=(const StdioProcess&) = delete;
  void Write(const std::string& bytes);
  std::string Read(Deadline deadline, const Cancelled& cancelled);
  void Close();
  bool Running() const;

 private:
  struct State;
  std::unique_ptr<State> state_;
};

std::string RunPowerShell(const std::wstring& script, const Cancelled& cancelled);
}  // namespace loongpass::codex
