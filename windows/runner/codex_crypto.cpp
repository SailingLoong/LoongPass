#include "codex_account_state.h"

#include <windows.h>
#include <bcrypt.h>
#include <wincrypt.h>

#include <array>
#include <limits>

namespace loongpass::codex {
namespace {
void Require(bool value) {
  if (!value) throw Failure(FailureCode::unavailable);
}
}  // namespace

std::string Digest(const std::string& data) {
  Require(data.size() <= (std::numeric_limits<ULONG>::max)());
  struct Algorithm {
    BCRYPT_ALG_HANDLE value = nullptr;
    ~Algorithm() { if (value) BCryptCloseAlgorithmProvider(value, 0); }
  } algorithm;
  Require(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_SHA256_ALGORITHM,
                                      nullptr, 0) >= 0);
  struct Hash {
    BCRYPT_HASH_HANDLE value = nullptr;
    ~Hash() { if (value) BCryptDestroyHash(value); }
  } hash;
  Require(BCryptCreateHash(algorithm.value, &hash.value, nullptr, 0, nullptr, 0, 0) >= 0);
  Require(BCryptHashData(hash.value,
      reinterpret_cast<PUCHAR>(const_cast<char*>(data.data())),
      static_cast<ULONG>(data.size()), 0) >= 0);
  std::array<unsigned char, 32> bytes = {};
  Require(BCryptFinishHash(hash.value, bytes.data(), static_cast<ULONG>(bytes.size()), 0) >= 0);
  constexpr char digits[] = "0123456789abcdef";
  std::string result;
  for (const auto byte : bytes) {
    result.push_back(digits[byte >> 4]);
    result.push_back(digits[byte & 15]);
  }
  return result;
}

std::string EncodeBase64(const std::string& data) {
  if (data.empty()) return {};
  Require(data.size() <= (std::numeric_limits<DWORD>::max)());
  DWORD length = 0;
  const auto* bytes = reinterpret_cast<const BYTE*>(data.data());
  const auto size = static_cast<DWORD>(data.size());
  constexpr DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
  Require(CryptBinaryToStringA(bytes, size, flags, nullptr, &length) != FALSE);
  std::string result(length, '\0');
  Require(CryptBinaryToStringA(bytes, size, flags, result.data(), &length) != FALSE);
  result.resize(length);
  if (!result.empty() && result.back() == '\0') result.pop_back();
  return result;
}

std::string DecodeBase64(const std::string& data) {
  if (data.empty()) return {};
  Require(data.size() <= 5 * 1024 * 1024 && data.size() % 4 == 0);
  const auto padding = data.find('=');
  const auto content = padding == std::string::npos ? data.size() : padding;
  Require(data.size() - content <= 2 &&
      data.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", 0) >= content);
  for (size_t index = content; index < data.size(); ++index) Require(data[index] == '=');
  DWORD length = 0;
  const auto size = static_cast<DWORD>(data.size());
  constexpr DWORD flags = CRYPT_STRING_BASE64 | CRYPT_STRING_STRICT;
  Require(CryptStringToBinaryA(data.data(), size, flags, nullptr, &length, nullptr, nullptr) != FALSE);
  std::string result(length, '\0');
  Require(CryptStringToBinaryA(data.data(), size, flags,
      reinterpret_cast<BYTE*>(result.data()), &length, nullptr, nullptr) != FALSE);
  result.resize(length);
  return result;
}
}  // namespace loongpass::codex
