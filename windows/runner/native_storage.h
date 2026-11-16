#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "native_support.h"

#include <filesystem>
#include <memory>

namespace loongpass {
// The same private directory, ACL, lifetime lock and durable JSON file owner is
// used by channel-backed stores and native account adapters.
class NativeAccountFile {
 public:
  static constexpr size_t maximumBytes = 5 * 1024 * 1024;
  explicit NativeAccountFile(const std::filesystem::path& root);
  ~NativeAccountFile();
  NativeAccountFile(const NativeAccountFile&) = delete;
  NativeAccountFile& operator=(const NativeAccountFile&) = delete;
  Json Read(const std::string& name, size_t limit = maximumBytes) const;
  void Write(const Json& value, const std::string& name,
             size_t limit = maximumBytes) const;
  const std::filesystem::path& root() const;
  void PrepareJournal() const;
  void FlushJournal() const;

 private:
  struct State;
  std::unique_ptr<State> state_;
};

std::filesystem::path ApplicationDataRoot();
bool HandleStorageCall(const std::string& channel, const Call& call,
                       std::unique_ptr<Result>& result);
}  // namespace loongpass
