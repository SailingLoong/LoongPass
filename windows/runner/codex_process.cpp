#include "codex_process.h"
#include "native_support.h"

#include <algorithm>
#include <array>
#include <cwchar>

namespace loongpass::codex {
namespace {
void Require(bool value) { if (!value) throw Failure(FailureCode::unavailable); }
struct Handle {
  HANDLE value = INVALID_HANDLE_VALUE;
  Handle() = default;
  explicit Handle(HANDLE raw) : value(raw) {}
  ~Handle() { Reset(); }
  void Reset(HANDLE raw = INVALID_HANDLE_VALUE) {
    if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value);
    value = raw;
  }
};
std::vector<wchar_t> Environment(const std::filesystem::path& home) {
  wchar_t* block = GetEnvironmentStringsW();
  Require(block != nullptr);
  std::vector<std::wstring> values;
  for (auto item = block; *item; item += std::wcslen(item) + 1) {
    const std::wstring entry(item);
    const auto end = entry.find(L'=', entry.front() == L'=' ? 1 : 0);
    const auto key = entry.substr(0, end);
    bool excluded = false;
    for (const auto* name : {L"CODEX_HOME", L"OPENAI_API_KEY", L"CODEX_API_KEY", L"CODEX_ACCESS_TOKEN"})
      if (_wcsicmp(key.c_str(), name) == 0) excluded = true;
    if (!excluded) values.push_back(entry);
  }
  FreeEnvironmentStringsW(block);
  values.push_back(L"CODEX_HOME=" + home.wstring());
  std::sort(values.begin(), values.end(), [](const auto& a, const auto& b) {
    return _wcsicmp(a.c_str(), b.c_str()) < 0;
  });
  std::vector<wchar_t> output;
  for (const auto& entry : values) {
    output.insert(output.end(), entry.begin(), entry.end());
    output.push_back(0);
  }
  output.push_back(0);
  return output;
}
}  // namespace

std::wstring QuoteArgument(const std::wstring& value) {
  std::wstring output = L"\"";
  size_t slashes = 0;
  for (const auto ch : value) {
    if (ch == L'\\') { ++slashes; continue; }
    output.append(slashes * (ch == L'\"' ? 2 : 1), L'\\');
    slashes = 0;
    if (ch == L'\"') output.push_back(L'\\');
    output.push_back(ch);
  }
  output.append(slashes * 2, L'\\');
  return output + L"\"";
}

struct StdioProcess::State {
  Handle process, job, input, output;
  bool closed = false;
};

StdioProcess::StdioProcess(const std::filesystem::path& executable,
    const std::vector<std::wstring>& arguments,
    const std::optional<std::filesystem::path>& home) : state_(std::make_unique<State>()) {
  SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
  Handle childInput, childOutput;
  HANDLE rawRead = nullptr, rawWrite = nullptr;
  Require(CreatePipe(&rawRead, &rawWrite, &security, 65536) != FALSE);
  childInput.Reset(rawRead); state_->input.Reset(rawWrite);
  Require(SetHandleInformation(state_->input.value, HANDLE_FLAG_INHERIT, 0) != FALSE);
  Require(CreatePipe(&rawRead, &rawWrite, &security, 65536) != FALSE);
  state_->output.Reset(rawRead); childOutput.Reset(rawWrite);
  Require(SetHandleInformation(state_->output.value, HANDLE_FLAG_INHERIT, 0) != FALSE);
  Handle error(CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE,
      &security, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  Require(error.value != INVALID_HANDLE_VALUE);
  std::array<HANDLE, 3> handles{childInput.value, childOutput.value, error.value};
  SIZE_T size = 0;
  InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
  std::vector<unsigned char> storage(size);
  auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
  Require(InitializeProcThreadAttributeList(attributes, 1, 0, &size) != FALSE);
  struct Attributes { LPPROC_THREAD_ATTRIBUTE_LIST value; ~Attributes() { DeleteProcThreadAttributeList(value); } } cleanup{attributes};
  Require(UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
      handles.data(), sizeof(handles), nullptr, nullptr) != FALSE);
  state_->job.Reset(CreateJobObjectW(nullptr, nullptr));
  Require(state_->job.value != nullptr);
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = {};
  limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  Require(SetInformationJobObject(state_->job.value, JobObjectExtendedLimitInformation,
      &limits, sizeof(limits)) != FALSE);
  STARTUPINFOEXW startup = {};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = childInput.value;
  startup.StartupInfo.hStdOutput = childOutput.value;
  startup.StartupInfo.hStdError = error.value;
  startup.lpAttributeList = attributes;
  std::wstring command = QuoteArgument(executable.wstring());
  for (const auto& argument : arguments) command += L" " + QuoteArgument(argument);
  auto environment = home ? Environment(*home) : std::vector<wchar_t>();
  PROCESS_INFORMATION process = {};
  Require(CreateProcessW(executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT | CREATE_SUSPENDED,
      home ? environment.data() : nullptr, home ? home->c_str() : nullptr,
      &startup.StartupInfo, &process) != FALSE);
  state_->process.Reset(process.hProcess);
  Handle thread(process.hThread);
  if (!AssignProcessToJobObject(state_->job.value, process.hProcess)) {
    TerminateProcess(process.hProcess, 1); WaitForSingleObject(process.hProcess, INFINITE);
    throw Failure(FailureCode::unavailable);
  }
  if (ResumeThread(thread.value) == static_cast<DWORD>(-1)) {
    TerminateJobObject(state_->job.value, 1); WaitForSingleObject(process.hProcess, INFINITE);
    throw Failure(FailureCode::unavailable);
  }
}
StdioProcess::~StdioProcess() { Close(); }
bool StdioProcess::Running() const {
  return !state_->closed && WaitForSingleObject(state_->process.value, 0) == WAIT_TIMEOUT;
}
void StdioProcess::Write(const std::string& bytes) {
  // Requests contain only small configuration/identity selectors, never grants.
  if (!Running() || bytes.size() > 32768) throw Failure(FailureCode::unavailable);
  DWORD written = 0;
  Require(WriteFile(state_->input.value, bytes.data(), static_cast<DWORD>(bytes.size()),
      &written, nullptr) && written == bytes.size());
}
std::string StdioProcess::Read(Deadline deadline, const Cancelled& cancelled) {
  while (!state_->closed) {
    if (cancelled && cancelled()) throw Failure(FailureCode::cancelled);
    if (std::chrono::steady_clock::now() >= deadline) throw Failure(FailureCode::timeout);
    DWORD available = 0;
    if (!PeekNamedPipe(state_->output.value, nullptr, 0, nullptr, &available, nullptr)) return {};
    if (available) {
      std::string output(std::min<DWORD>(available, 65536), '\0');
      DWORD count = 0;
      Require(ReadFile(state_->output.value, output.data(), static_cast<DWORD>(output.size()), &count, nullptr) != FALSE);
      output.resize(count);
      return output;
    }
    if (!Running()) return {};
    WaitForSingleObject(state_->process.value, 15);
  }
  return {};
}
void StdioProcess::Close() {
  if (!state_ || state_->closed) return;
  state_->closed = true;
  state_->input.Reset();  // Give the official child EOF and time to flush its final grant.
  if (state_->process.value != INVALID_HANDLE_VALUE &&
      WaitForSingleObject(state_->process.value, 1500) == WAIT_TIMEOUT) {
    TerminateJobObject(state_->job.value, 1);
    WaitForSingleObject(state_->process.value, INFINITE);
  }
  state_->job.Reset(); state_->output.Reset(); state_->process.Reset();
}

std::string RunPowerShell(const std::wstring& script, const Cancelled& cancelled) {
  wchar_t system[MAX_PATH + 1] = {};
  Require(GetSystemDirectoryW(system, MAX_PATH) != 0);
  const auto executable = std::filesystem::path(system) / L"WindowsPowerShell/v1.0/powershell.exe";
  const auto bytes = std::string(reinterpret_cast<const char*>(script.data()), script.size() * sizeof(wchar_t));
  StdioProcess process(executable, {L"-NoLogo", L"-NoProfile", L"-NonInteractive", L"-EncodedCommand", Wide(EncodeBase64(bytes))});
  std::string output;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (true) {
    const auto part = process.Read(deadline, cancelled);
    if (part.empty()) break;
    output += part;
    if (output.size() > 1024 * 1024) throw Failure(FailureCode::protocolError);
  }
  process.Close();
  if (output.rfind("\xef\xbb\xbf", 0) == 0) output.erase(0, 3);
  return output;
}
}  // namespace loongpass::codex
