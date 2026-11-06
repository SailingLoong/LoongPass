#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "native_support.h"

#include <filesystem>
#include <memory>

namespace loongpass {
std::filesystem::path ApplicationDataRoot();
bool HandleStorageCall(const std::string& channel, const Call& call,
                       std::unique_ptr<Result>& result);
}  // namespace loongpass
