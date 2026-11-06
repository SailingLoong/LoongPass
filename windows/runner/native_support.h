#pragma once

#include <windows.h>
#include <bcrypt.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_result.h>
#include <nlohmann/json.hpp>

#include <stdexcept>
#include <string>
#include <vector>

namespace loongpass {
using Json = nlohmann::json;
using Value = flutter::EncodableValue;
using Call = flutter::MethodCall<Value>;
using Result = flutter::MethodResult<Value>;

inline std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0);
  if (!size) throw std::runtime_error("Invalid UTF-8");
  std::wstring output(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), output.data(), size);
  return output;
}

inline std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                                 static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  if (!size) throw std::runtime_error("Invalid UTF-16");
  std::string output(size, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), output.data(), size, nullptr, nullptr);
  return output;
}

inline Json Decode(const Value* value) {
  if (!value || std::holds_alternative<std::monostate>(*value)) return nullptr;
  if (auto v = std::get_if<bool>(value)) return *v;
  if (auto v = std::get_if<int32_t>(value)) return *v;
  if (auto v = std::get_if<int64_t>(value)) return *v;
  if (auto v = std::get_if<double>(value)) return *v;
  if (auto v = std::get_if<std::string>(value)) return *v;
  if (auto v = std::get_if<flutter::EncodableList>(value)) {
    auto output = Json::array();
    for (const auto& item : *v) output.push_back(Decode(&item));
    return output;
  }
  if (auto v = std::get_if<flutter::EncodableMap>(value)) {
    auto output = Json::object();
    for (const auto& item : *v) {
      output[std::get<std::string>(item.first)] = Decode(&item.second);
    }
    return output;
  }
  throw std::runtime_error("Unsupported channel value");
}

inline Value Encode(const Json& value) {
  if (value.is_null()) return Value();
  if (value.is_boolean()) return Value(value.get<bool>());
  if (value.is_number_integer()) return Value(value.get<int64_t>());
  if (value.is_number_float()) return Value(value.get<double>());
  if (value.is_string()) return Value(value.get<std::string>());
  if (value.is_array()) {
    flutter::EncodableList output;
    for (const auto& item : value) output.push_back(Encode(item));
    return Value(output);
  }
  flutter::EncodableMap output;
  for (const auto& item : value.items()) output[Value(item.key())] = Encode(item.value());
  return Value(output);
}

inline std::string RandomHex(size_t count) {
  std::vector<unsigned char> bytes(count);
  if (BCryptGenRandom(nullptr, bytes.data(), static_cast<ULONG>(bytes.size()),
                      BCRYPT_USE_SYSTEM_PREFERRED_RNG) < 0) {
    throw std::runtime_error("Random source unavailable");
  }
  const char* digits = "0123456789abcdef";
  std::string output;
  output.reserve(count * 2);
  for (auto byte : bytes) {
    output.push_back(digits[byte >> 4]);
    output.push_back(digits[byte & 15]);
  }
  return output;
}
}  // namespace loongpass
