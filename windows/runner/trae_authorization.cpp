#include "trae_authorization.h"

#include <ncrypt.h>
#include <wincrypt.h>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <limits>
#include <regex>

namespace loongpass {
namespace {

using Bytes = std::vector<unsigned char>;

void Require(bool condition) {
  if (!condition) throw std::runtime_error("TRAE authorization unavailable");
}

// Buffers containing decrypted material or private key bytes are erased before
// release. Account JSON is returned only to the existing Dart account owner.
struct SecretBytes {
  Bytes value;
  ~SecretBytes() {
    if (!value.empty()) SecureZeroMemory(value.data(), value.size());
  }
};

struct Algorithm {
  BCRYPT_ALG_HANDLE value = nullptr;
  ~Algorithm() {
    if (value) BCryptCloseAlgorithmProvider(value, 0);
  }
};

struct Key {
  BCRYPT_KEY_HANDLE value = nullptr;
  ~Key() {
    if (value) BCryptDestroyKey(value);
  }
};

struct StorageProvider {
  NCRYPT_PROV_HANDLE value = 0;
  ~StorageProvider() {
    if (value) NCryptFreeObject(value);
  }
};

struct SigningKey {
  NCRYPT_KEY_HANDLE value = 0;
  ~SigningKey() {
    if (value) NCryptFreeObject(value);
  }
};

Bytes Base64(const std::string& text, DWORD format) {
  DWORD size = 0;
  Require(CryptStringToBinaryA(text.data(), static_cast<DWORD>(text.size()),
                              format, nullptr, &size, nullptr, nullptr));
  Bytes bytes(size);
  Require(CryptStringToBinaryA(text.data(), static_cast<DWORD>(text.size()),
                              format, bytes.data(), &size, nullptr, nullptr));
  bytes.resize(size);
  return bytes;
}

std::string Base64(const Bytes& bytes) {
  DWORD size = 0;
  const DWORD format = CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF;
  Require(CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                              format, nullptr, &size));
  std::string text(size, '\0');
  Require(CryptBinaryToStringA(bytes.data(), static_cast<DWORD>(bytes.size()),
                              format, text.data(), &size));
  text.resize(size);
  while (!text.empty() && text.back() == '\0') text.pop_back();
  return text;
}

Bytes Hash(LPCWSTR algorithm, const unsigned char* input, size_t size) {
  Algorithm provider;
  Require(BCryptOpenAlgorithmProvider(&provider.value, algorithm, nullptr, 0) >= 0);
  DWORD count = 0, written = 0;
  Require(BCryptGetProperty(provider.value, BCRYPT_HASH_LENGTH,
                            reinterpret_cast<PUCHAR>(&count), sizeof(count),
                            &written, 0) >= 0);
  Bytes digest(count);
  Require(BCryptHash(provider.value, nullptr, 0,
                     const_cast<PUCHAR>(input), static_cast<ULONG>(size),
                     digest.data(), count) >= 0);
  return digest;
}

Bytes Hex(const char* input) {
  Bytes output;
  for (size_t index = 0; input[index]; index += 2) {
    auto digit = [](char value) -> unsigned char {
      return static_cast<unsigned char>(value <= '9' ? value - '0'
                                                     : value - 'a' + 10);
    };
    output.push_back(static_cast<unsigned char>((digit(input[index]) << 4) |
                                                digit(input[index + 1])));
  }
  return output;
}

Json DecodeByteCrypto(const std::string& encoded) {
  Require(encoded.size() <= 1'000'000);
  const auto packed = Base64(encoded, CRYPT_STRING_BASE64);
  Require(packed.size() >= 118 && (packed.size() - 38) % 16 == 0);
  const std::array<unsigned char, 6> first = {116, 99, 5, 16, 0, 0};
  const std::array<unsigned char, 6> second = {18, 57, 32, 32, 2, 3};
  Bytes salt;
  if (std::equal(first.begin(), first.end(), packed.begin())) {
    salt = Hex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f"
               "49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58");
  } else if (std::equal(second.begin(), second.end(), packed.begin())) {
    salt = Hex("490cc21292b05d0cc06ccbe91fb92e21b5a7c538811dc85e27a96e28104e1cf69c"
               "7166efab232807390da78a8b91e49c44b49a43feb941a1e46f2656e613e47b");
  } else {
    Require(false);
  }
  SecretBytes seed{Hash(BCRYPT_SHA512_ALGORITHM, packed.data() + 6, 32)};
  seed.value.insert(seed.value.end(), salt.begin(), salt.end());
  SecretBytes derived{Hash(BCRYPT_SHA512_ALGORITHM, seed.value.data(),
                           seed.value.size())};
  Algorithm algorithm;
  Require(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_AES_ALGORITHM,
                                      nullptr, 0) >= 0);
  Require(BCryptSetProperty(algorithm.value, BCRYPT_CHAINING_MODE,
                            reinterpret_cast<PUCHAR>(
                                const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_CBC)),
                            sizeof(BCRYPT_CHAIN_MODE_CBC), 0) >= 0);
  Key key;
  Require(BCryptGenerateSymmetricKey(algorithm.value, &key.value, nullptr, 0,
                                     derived.value.data(), 16, 0) >= 0);
  std::array<unsigned char, 16> iv;
  std::copy_n(derived.value.begin() + 16, iv.size(), iv.begin());
  SecretBytes clear{Bytes(packed.size() - 38)};
  ULONG size = 0;
  Require(BCryptDecrypt(key.value, const_cast<PUCHAR>(packed.data() + 38),
                         static_cast<ULONG>(packed.size() - 38), nullptr,
                         iv.data(), static_cast<ULONG>(iv.size()),
                         clear.value.data(), static_cast<ULONG>(clear.value.size()),
                         &size, BCRYPT_BLOCK_PADDING) >= 0);
  Require(size >= 64 && size <= clear.value.size());
  const auto digest = Hash(BCRYPT_SHA512_ALGORITHM, clear.value.data() + 64,
                           size - 64);
  unsigned char difference = 0;
  for (size_t index = 0; index < digest.size(); ++index) {
    difference |= digest[index] ^ clear.value[index];
  }
  Require(difference == 0);
  auto value = Json::parse(clear.value.begin() + 64,
                           clear.value.begin() + size);
  Require(value.is_object());
  return value;
}

void ImportPrivate(const std::string& pem, StorageProvider& provider,
                   SigningKey& key) {
  Require(!pem.empty() && pem.size() < 16384 &&
          pem.find("-----BEGIN PRIVATE KEY-----") == 0);
  SecretBytes bytes{Base64(pem, CRYPT_STRING_BASE64HEADER)};
  Require(NCryptOpenStorageProvider(&provider.value, MS_KEY_STORAGE_PROVIDER, 0) ==
          ERROR_SUCCESS);
  // No key name or persistence option is supplied. CNG owns only an ephemeral
  // imported key for this operation.
  Require(NCryptImportKey(provider.value, 0, NCRYPT_PKCS8_PRIVATE_KEY_BLOB,
                          nullptr, &key.value, bytes.value.data(),
                          static_cast<DWORD>(bytes.value.size()),
                          NCRYPT_SILENT_FLAG) == ERROR_SUCCESS);
}

Bytes PublicPart(NCRYPT_KEY_HANDLE key) {
  DWORD size = 0;
  Require(NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, nullptr, 0,
                          &size, 0) == ERROR_SUCCESS);
  Bytes bytes(size);
  Require(NCryptExportKey(key, 0, BCRYPT_ECCPUBLIC_BLOB, nullptr, bytes.data(),
                          size, &size, 0) == ERROR_SUCCESS);
  bytes.resize(size);
  Require(bytes.size() == sizeof(BCRYPT_ECCKEY_BLOB) + 64);
  BCRYPT_ECCKEY_BLOB header;
  std::memcpy(&header, bytes.data(), sizeof(header));
  Require(header.dwMagic == BCRYPT_ECDSA_PUBLIC_P256_MAGIC && header.cbKey == 32);
  return bytes;
}

void ValidatePublicPair(NCRYPT_KEY_HANDLE private_key,
                        const std::string& public_pem) {
  Require(public_pem.size() < 16384 &&
          public_pem.find("-----BEGIN PUBLIC KEY-----") == 0);
  const auto bytes = Base64(public_pem, CRYPT_STRING_BASE64HEADER);
  CERT_PUBLIC_KEY_INFO* info = nullptr;
  DWORD size = 0;
  Require(CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
                              bytes.data(), static_cast<DWORD>(bytes.size()),
                              CRYPT_DECODE_ALLOC_FLAG, nullptr, &info, &size));
  Key public_key;
  const BOOL imported = CryptImportPublicKeyInfoEx2(
      X509_ASN_ENCODING, info, CRYPT_OID_INFO_PUBKEY_SIGN_KEY_FLAG, nullptr,
      &public_key.value);
  LocalFree(info);
  Require(imported != FALSE);
  ULONG count = 0;
  Require(BCryptExportKey(public_key.value, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                          nullptr, 0, &count, 0) >= 0);
  Bytes actual(count);
  Require(BCryptExportKey(public_key.value, nullptr, BCRYPT_ECCPUBLIC_BLOB,
                          actual.data(), count, &count, 0) >= 0);
  actual.resize(count);
  Require(PublicPart(private_key) == actual);
}

Bytes SignatureDer(const Bytes& signature) {
  Require(signature.size() == 64);
  Bytes integers;
  for (size_t offset : {size_t(0), size_t(32)}) {
    size_t first = offset;
    while (first + 1 < offset + 32 && signature[first] == 0) ++first;
    const bool padding = (signature[first] & 0x80) != 0;
    integers.push_back(0x02);
    integers.push_back(static_cast<unsigned char>(offset + 32 - first +
                                                  (padding ? 1 : 0)));
    if (padding) integers.push_back(0);
    integers.insert(integers.end(), signature.begin() + first,
                     signature.begin() + offset + 32);
  }
  Bytes output{0x30, static_cast<unsigned char>(integers.size())};
  output.insert(output.end(), integers.begin(), integers.end());
  return output;
}

int64_t ExpiryMilliseconds(const Json& value) {
  if (value.is_number_unsigned()) {
    const auto number = value.get<uint64_t>();
    Require(number > 0 && number <=
        static_cast<uint64_t>((std::numeric_limits<int64_t>::max)()));
    return static_cast<int64_t>(number);
  }
  if (value.is_number_integer()) {
    const auto number = value.get<int64_t>();
    Require(number > 0);
    return number;
  }
  if (value.is_number()) {
    const double number = value.get<double>();
    Require(std::isfinite(number) && number > 0 &&
            number < static_cast<double>((std::numeric_limits<int64_t>::max)()));
    return static_cast<int64_t>(number);
  }
  Require(value.is_string());
  static const std::regex format(
      R"(^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?(Z|[+-][0-9]{2}:[0-9]{2})$)");
  std::smatch parts;
  const auto text = value.get<std::string>();
  Require(std::regex_match(text, parts, format));
  SYSTEMTIME time{};
  time.wYear = static_cast<WORD>(std::stoi(parts[1].str()));
  time.wMonth = static_cast<WORD>(std::stoi(parts[2].str()));
  time.wDay = static_cast<WORD>(std::stoi(parts[3].str()));
  time.wHour = static_cast<WORD>(std::stoi(parts[4].str()));
  time.wMinute = static_cast<WORD>(std::stoi(parts[5].str()));
  time.wSecond = static_cast<WORD>(std::stoi(parts[6].str()));
  const auto fraction = parts[7].str();
  if (!fraction.empty()) {
    time.wMilliseconds = static_cast<WORD>(std::stoi((fraction + "000").substr(0, 3)));
  }
  FILETIME file_time{};
  Require(SystemTimeToFileTime(&time, &file_time) != FALSE);
  ULARGE_INTEGER ticks;
  ticks.LowPart = file_time.dwLowDateTime;
  ticks.HighPart = file_time.dwHighDateTime;
  int64_t milliseconds = static_cast<int64_t>(ticks.QuadPart / 10000) -
                         11644473600000LL;
  const auto zone = parts[8].str();
  if (zone != "Z") {
    const int hours = std::stoi(zone.substr(1, 2));
    const int minutes = std::stoi(zone.substr(4, 2));
    Require(hours <= 23 && minutes <= 59);
    const int64_t offset = (hours * 60LL + minutes) * 60000;
    milliseconds += zone[0] == '+' ? -offset : offset;
  }
  Require(milliseconds > 0);
  return milliseconds;
}

}  // namespace

Json DecodeTraeAuthorization(const Json& source, const std::string& version,
                             const Json& device_facts) {
  const auto user = DecodeByteCrypto(
      source.at("iCubeAuthInfo://icube.cloudide").get<std::string>());
  const auto& account = user.at("account");
  Require(account.is_object() && account.value("scope", "") == "marscode" &&
          account.value("loginScope", "") == "trae" &&
          user.value("host", "") == "https://api.trae.cn");
  const auto uid = user.at("userId").get<std::string>();
  const auto token = user.at("token").get<std::string>();
  const auto machine = source.at("telemetry.machineId").get<std::string>();
  Require(!uid.empty() && !token.empty() && !machine.empty());
  std::string key_name;
  constexpr char prefix[] = "iCubeAuthInfo://icube-dc:";
  for (const auto& entry : source.items()) {
    if (entry.key().rfind(prefix, 0) != 0) continue;
    Require(key_name.empty());
    key_name = entry.key();
  }
  Require(key_name.size() > sizeof(prefix) - 1);
  const auto pair = DecodeByteCrypto(source.at(key_name).get<std::string>());
  const auto private_pem = pair.at("privateKeyPEM").get<std::string>();
  const auto public_pem = pair.at("publicKeyPEM").get<std::string>();
  StorageProvider provider;
  SigningKey key;
  ImportPrivate(private_pem, provider, key);
  ValidatePublicPair(key.value, public_pem);
  auto device = device_facts;
  device["DeviceID"] = key_name.substr(sizeof(prefix) - 1);
  device["MachineID"] = machine;
  device["PlatformCode"] = "IDE_PC";
  device["DeviceType"] = "PC";
  device["ClientVersion"] = version;
  device["DevicePublicKey"] = public_pem;
  // The imported official session keeps ownership of its rotating refresh token.
  return {{"account", {{"uid", uid}, {"token", token},
                       {"expiresAt", ExpiryMilliseconds(user.at("expiredAt"))},
                       {"label", account.value("username", uid)},
                       {"owner", "officialClient"}}},
          {"device", device}, {"privateKeyPEM", private_pem}, {"version", version}};
}

Json SignTraeRefresh(const std::string& private_pem,
                     const std::string& refresh_token) {
  Require(!refresh_token.empty() && refresh_token.size() <= 16384);
  StorageProvider provider;
  SigningKey key;
  ImportPrivate(private_pem, provider, key);
  PublicPart(key.value);  // Enforce the existing P-256 signing contract.
  const auto nonce = RandomHex(16);
  const auto timestamp = std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::system_clock::now().time_since_epoch()).count();
  const auto message = std::string("POST\n/trae/api/v3/oauth/ExchangeToken\n") +
                       "ono9krqynydwx5\n" + refresh_token + "\n" +
                       std::to_string(timestamp) + "\n" + nonce;
  const auto digest = Hash(BCRYPT_SHA256_ALGORITHM,
                           reinterpret_cast<const unsigned char*>(message.data()),
                           message.size());
  DWORD size = 0;
  Require(NCryptSignHash(key.value, nullptr, const_cast<PUCHAR>(digest.data()),
                         static_cast<DWORD>(digest.size()), nullptr, 0, &size,
                         0) == ERROR_SUCCESS);
  Bytes signature(size);
  Require(NCryptSignHash(key.value, nullptr, const_cast<PUCHAR>(digest.data()),
                         static_cast<DWORD>(digest.size()), signature.data(), size,
                         &size, 0) == ERROR_SUCCESS);
  signature.resize(size);
  return {{"Signature", Base64(SignatureDer(signature))},
          {"Timestamp", timestamp}, {"Nonce", nonce}};
}

}  // namespace loongpass

#ifdef LOONGPASS_AUTHORIZATION_SELF_TEST
#include <iostream>

namespace loongpass {
namespace {

std::pair<std::string, std::string> SyntheticKeyPair() {
  StorageProvider provider;
  SigningKey key;
  Require(NCryptOpenStorageProvider(&provider.value, MS_KEY_STORAGE_PROVIDER, 0) ==
          ERROR_SUCCESS);
  Require(NCryptCreatePersistedKey(provider.value, &key.value,
      NCRYPT_ECDSA_P256_ALGORITHM, nullptr, 0, 0) == ERROR_SUCCESS);
  DWORD policy = NCRYPT_ALLOW_PLAINTEXT_EXPORT_FLAG | NCRYPT_ALLOW_EXPORT_FLAG;
  Require(NCryptSetProperty(key.value, NCRYPT_EXPORT_POLICY_PROPERTY,
      reinterpret_cast<PUCHAR>(&policy), sizeof(policy), 0) == ERROR_SUCCESS);
  Require(NCryptFinalizeKey(key.value, 0) == ERROR_SUCCESS);
  DWORD size = 0;
  Require(NCryptExportKey(key.value, 0, NCRYPT_PKCS8_PRIVATE_KEY_BLOB, nullptr,
      nullptr, 0, &size, 0) == ERROR_SUCCESS);
  SecretBytes encoded{Bytes(size)};
  Require(NCryptExportKey(key.value, 0, NCRYPT_PKCS8_PRIVATE_KEY_BLOB, nullptr,
      encoded.value.data(), size, &size, 0) == ERROR_SUCCESS);
  encoded.value.resize(size);
  const auto private_pem = std::string("-----BEGIN PRIVATE KEY-----\n") +
      Base64(encoded.value) + "\n-----END PRIVATE KEY-----\n";
  const auto public_blob = PublicPart(key.value);
  auto public_der = Hex("3059301306072a8648ce3d020106082a8648ce3d03010703420004");
  public_der.insert(public_der.end(), public_blob.begin() + sizeof(BCRYPT_ECCKEY_BLOB),
                      public_blob.end());
  return {private_pem, std::string("-----BEGIN PUBLIC KEY-----\n") +
      Base64(public_der) + "\n-----END PUBLIC KEY-----\n"};
}

std::string SyntheticByteCrypto(const Json& value) {
  const auto text = value.dump();
  Bytes clear = Hash(BCRYPT_SHA512_ALGORITHM,
      reinterpret_cast<const unsigned char*>(text.data()), text.size());
  clear.insert(clear.end(), text.begin(), text.end());
  Bytes packed = {116, 99, 5, 16, 0, 0};
  for (unsigned char index = 0; index < 32; ++index) packed.push_back(index);
  auto seed = Hash(BCRYPT_SHA512_ALGORITHM, packed.data() + 6, 32);
  const auto salt = Hex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f"
                        "49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58");
  seed.insert(seed.end(), salt.begin(), salt.end());
  const auto derived = Hash(BCRYPT_SHA512_ALGORITHM, seed.data(), seed.size());
  Algorithm algorithm;
  Require(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_AES_ALGORITHM,
                                      nullptr, 0) >= 0);
  Require(BCryptSetProperty(algorithm.value, BCRYPT_CHAINING_MODE,
      reinterpret_cast<PUCHAR>(const_cast<wchar_t*>(BCRYPT_CHAIN_MODE_CBC)),
      sizeof(BCRYPT_CHAIN_MODE_CBC), 0) >= 0);
  Key key;
  Require(BCryptGenerateSymmetricKey(algorithm.value, &key.value, nullptr, 0,
      const_cast<PUCHAR>(derived.data()), 16, 0) >= 0);
  Bytes iv(derived.begin() + 16, derived.begin() + 32);
  Bytes cipher(clear.size() + 16);
  ULONG written = 0;
  Require(BCryptEncrypt(key.value, clear.data(), static_cast<ULONG>(clear.size()),
      nullptr, iv.data(), static_cast<ULONG>(iv.size()), cipher.data(),
      static_cast<ULONG>(cipher.size()), &written, BCRYPT_BLOCK_PADDING) >= 0);
  packed.insert(packed.end(), cipher.begin(), cipher.begin() + written);
  return Base64(packed);
}

Bytes ParseSignature(const Bytes& der) {
  Require(der.size() >= 8 && der[0] == 0x30 && der[1] == der.size() - 2);
  Bytes raw(64);
  size_t index = 2;
  for (size_t component = 0; component < 2; ++component) {
    Require(index + 2 <= der.size() && der[index++] == 2);
    size_t size = der[index++];
    Require(size > 0 && size <= 33 && index + size <= der.size() &&
            (der[index] & 0x80) == 0);
    if (der[index] == 0 && size > 1) { ++index; --size; }
    Require(size <= 32);
    std::copy_n(der.begin() + index, size, raw.begin() + component * 32 + 32 - size);
    index += size;
  }
  Require(index == der.size());
  return raw;
}

int AuthorizationSelfTest() {
  // Public, synthetic vectors generated independently with Python hashlib and
  // OpenSSL AES-128-CBC. No installed client or account file is read.
  const std::array<const char*, 2> vectors = {
      "dGMFEAAAAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8l+uWouLueLRcTNzAjgxP94JFwoXsYi3X5loh6t4wiAGY2NX+oYMnQ91JhuFB7ctZo+CmP2vEW44rMcWJtQBEzaKM93Dvt+oNATCarHCJrixcS0zQaCPu7F6oYvziPI7QVy68WIyvU/duo6bD6uMNaLrxcGhn2xwqK9CZl0EYFrrsTvPHOjVa/9ERsTkCDCll/Av4JzEIaR3eb0rMTYM9m258NDzW5aYUNh1aHTv4a3Nr6OSTD1S/WJkc/MlkQ7PLULvoS173FbfkC8rK5hvavvta8FQxo2TWNtZ1cIm52qzW+6o++YgnhdEwuf/JjYcCPoCSS+KxXEaEF4SVq+sqDYkTnJoPPqv9tmvsQ2NpVww==",
      "EjkgIAIDAAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh/ZwalHnpG8bZspeOyTtqIPX/WD/eY/U/Adgt9Z03VC64akiOXZPrXzB2echir+vh/r60ngg821oEWedhAqHRB67YG7cl+J7QCuxWuIvdtS8gEYIakP4vGy+ZXNWI5PIJo5qu0R0TwhAMZWhaFhlcZal+dmIjX8me3+o/WD5lxBdrvxEPwZQ+PHQqNn/k0NG/MKyw4Pr4UqkmH9RvgbGPWqSYXHIyMnBNrsOcNLPDutGx5Q4cByLbryF0fErwkEnDh44cL66H2chk5JI6bQReFnJ+IGCVZo52HD8ag2w0xAO5QafbTrRGQEGht+g4Y1/+0+nLjGJE/3VWgU7/ZYFaK5QjBrhcMS1LRHzlFrlPF1ew=="};
  const auto pair = SyntheticKeyPair();
  const auto encrypted_pair = SyntheticByteCrypto(
      {{"privateKeyPEM", pair.first}, {"publicKeyPEM", pair.second}});
  for (const auto* vector : vectors) {
    const Json source = {{"iCubeAuthInfo://icube.cloudide", vector},
        {"telemetry.machineId", "synthetic-machine"},
        {"iCubeAuthInfo://icube-dc:synthetic-device", encrypted_pair}};
    const auto decoded = DecodeTraeAuthorization(source, "1.2.3",
                                                  {{"OSInfo", "Windows"}});
    Require(decoded.at("account").at("uid") == "synthetic-user");
    Require(decoded.at("account").at("token") == "synthetic-access");
    Require(decoded.at("account").at("owner") == "officialClient");
    Require(decoded.at("account").at("expiresAt") == 1794099600000LL);
    Require(decoded.at("device").at("DeviceID") == "synthetic-device");
    Require(decoded.at("device").at("MachineID") == "synthetic-machine");
    Require(decoded.at("privateKeyPEM") == pair.first);
    auto corrupted = Base64(vector, CRYPT_STRING_BASE64);
    corrupted.back() ^= 1;
    bool rejected = false;
    try { DecodeByteCrypto(Base64(corrupted)); }
    catch (...) { rejected = true; }
    Require(rejected);
  }
  bool mismatch_rejected = false;
  try {
    StorageProvider provider;
    SigningKey key;
    ImportPrivate(pair.first, provider, key);
    ValidatePublicPair(key.value, SyntheticKeyPair().second);
  } catch (...) { mismatch_rejected = true; }
  Require(mismatch_rejected);
  const auto now_seconds = [] {
    return std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
  };
  const auto before = now_seconds();
  const auto signed_reply = SignTraeRefresh(pair.first, "synthetic-refresh");
  const auto after = now_seconds();
  const auto timestamp = signed_reply.at("Timestamp").get<int64_t>();
  const auto nonce = signed_reply.at("Nonce").get<std::string>();
  Require(timestamp >= before && timestamp <= after && timestamp < 100000000000LL);
  Require(std::regex_match(nonce, std::regex("^[0-9a-f]{32}$")));
  const auto message = std::string("POST\n/trae/api/v3/oauth/ExchangeToken\n") +
      "ono9krqynydwx5\nsynthetic-refresh\n" + std::to_string(timestamp) + "\n" + nonce;
  const auto hash = Hash(BCRYPT_SHA256_ALGORITHM,
      reinterpret_cast<const unsigned char*>(message.data()), message.size());
  const auto signature = ParseSignature(Base64(
      signed_reply.at("Signature").get<std::string>(), CRYPT_STRING_BASE64));
  StorageProvider provider;
  SigningKey private_key;
  ImportPrivate(pair.first, provider, private_key);
  const auto public_blob = PublicPart(private_key.value);
  Algorithm algorithm;
  Key public_key;
  Require(BCryptOpenAlgorithmProvider(&algorithm.value, BCRYPT_ECDSA_P256_ALGORITHM,
                                      nullptr, 0) >= 0);
  Require(BCryptImportKeyPair(algorithm.value, nullptr, BCRYPT_ECCPUBLIC_BLOB,
      &public_key.value, const_cast<PUCHAR>(public_blob.data()),
      static_cast<ULONG>(public_blob.size()), 0) >= 0);
  Require(BCryptVerifySignature(public_key.value, nullptr,
      const_cast<PUCHAR>(hash.data()), static_cast<ULONG>(hash.size()),
      const_cast<PUCHAR>(signature.data()), static_cast<ULONG>(signature.size()), 0) >= 0);
  auto changed = hash;
  changed.front() ^= 1;
  Require(BCryptVerifySignature(public_key.value, nullptr, changed.data(),
      static_cast<ULONG>(changed.size()), const_cast<PUCHAR>(signature.data()),
      static_cast<ULONG>(signature.size()), 0) < 0);
  Require(ExpiryMilliseconds(Json("2026-11-08T01:00:00Z")) == 1794099600000LL);
  Require(ExpiryMilliseconds(Json(1794099600000LL)) == 1794099600000LL);
  Require(ExpiryMilliseconds(Json("2026-11-08T01:00:00.123Z")) == 1794099600123LL);
  std::cout << "TRAE synthetic byteCrypto, PKCS8/P256 DER, timestamp and nonce checks passed\n";
  return 0;
}

}  // namespace
}  // namespace loongpass

int main() {
  try { return loongpass::AuthorizationSelfTest(); }
  catch (...) {
    std::cerr << "TRAE synthetic authorization checks failed\n";
    return 1;
  }
}
#endif
