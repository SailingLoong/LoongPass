#include "codex_account_state.h"

#include <windows.h>

#include <algorithm>
#include <set>

namespace loongpass::codex {
namespace {
constexpr const char* kAuthNamespace = "https://api.openai.com/auth";
constexpr const char* kRenderer = "electron-account-renderer-state-v1";
constexpr const char* kAtoms = "electron-persisted-atom-state";

void Require(bool value, FailureCode code = FailureCode::invalidCredential) {
  if (!value) throw Failure(code);
}

std::wstring Wide(const std::string& text) {
  const auto length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  Require(length > 0);
  std::wstring result(length, L'\0');
  Require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), result.data(), length) == length);
  return result;
}

std::optional<std::string> Text(const Json& value) {
  if (value.is_null()) return std::nullopt;
  Require(value.is_string());
  const auto text = value.get<std::string>();
  Require(!text.empty() && text.size() <= 65536);
  const auto wide = Wide(text);
  std::vector<WORD> types(wide.size());
  Require(GetStringTypeW(CT_CTYPE1, wide.data(), static_cast<int>(wide.size()), types.data()) != FALSE);
  Require((types.front() & C1_SPACE) == 0 && (types.back() & C1_SPACE) == 0 &&
      std::none_of(types.begin(), types.end(), [](WORD type) { return (type & C1_CNTRL) != 0; }));
  return text;
}

Json Get(const Json& value, const char* key) {
  return value.is_object() && value.contains(key) ? value.at(key) : Json();
}

std::string Identity(std::initializer_list<Json> values) {
  std::optional<std::string> result;
  for (const auto& value : values) {
    if (value.is_null()) continue;
    const auto text = Text(value);
    Require(text && text->size() <= 512 && (!result || result == text));
    result = text;
  }
  Require(result.has_value());
  return *result;
}

Json Claims(const std::string& token) {
  const auto first = token.find('.');
  const auto second = token.find('.', first == std::string::npos ? 0 : first + 1);
  Require(first != std::string::npos && first > 0 && second != std::string::npos &&
      second > first + 1 && second + 1 < token.size() && token.find('.', second + 1) == std::string::npos);
  auto payload = token.substr(first + 1, second - first - 1);
  std::replace(payload.begin(), payload.end(), '-', '+');
  std::replace(payload.begin(), payload.end(), '_', '/');
  payload.append((4 - payload.size() % 4) % 4, '=');
  const auto value = Json::parse(DecodeBase64(payload));
  Require(value.is_object());
  return value;
}

std::wstring Lower(const std::string& text) {
  auto value = Wide(text);
  const auto count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE,
      value.data(), static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr, 0);
  Require(count > 0);
  std::wstring result(count, L'\0');
  Require(LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, value.data(),
      static_cast<int>(value.size()), result.data(), count, nullptr, nullptr, 0) == count);
  return result;
}

Json SettingsDocument(const std::string& data) {
  Require(!data.empty() && data.size() <= LocalSettings::maximumBytes,
          FailureCode::settingsUnavailable);
  const auto document = Json::parse(data);
  Require(document.is_object(), FailureCode::settingsUnavailable);
  for (const auto& item : document.items()) {
    Require(item.key().rfind("electron-account-renderer-state-", 0) != 0 || item.key() == kRenderer,
            FailureCode::settingsUnavailable);
  }
  return document;
}

const std::set<std::string> kLocalGlobals = {
    "open-in-target-preferences", "worktree-repository-preferences", "active-workspace-roots",
    "electron-saved-workspace-roots", "electron-workspace-root-labels", "local-projects",
    "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
    "selected-project", "project-writable-roots", "project-appearances", "project-files",
    "pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host", "pinned-project-ids",
    "sidebar-project-thread-orders", "sidebar-thread-metadata", "thread-project-assignments",
    "thread-project-membership-host-ids", "thread-writable-roots", "thread-workspace-root-hints",
    "thread-projectless-output-directories", "projectless-thread-ids", "project-order"};

bool LocalAtom(const std::string& key) {
  static const std::set<std::string> local = {
      "composer-prompt-drafts-v1", "composer-prompt-drafts-v2", "composer-recent-model-configurations-v1",
      "composer-auto-context-enabled", "prompt-history", "flat-project-sidebar-preferences-v1",
      "sidebar-custom-sections-v3", "sidebar-collapsed-sections-v1", "agent-mode-by-host-id"};
  return local.count(key) != 0 || key.rfind("sidebar-project-expanded-v1-codex:", 0) == 0 ||
      key.rfind("thread-tab-routes-v1:", 0) == 0 || key.rfind("permission-selection-by-host-id:", 0) == 0;
}
}  // namespace

Credential::Credential(std::string bytes) : data(std::move(bytes)) {
  try {
    Require(!data.empty() && data.size() <= 1024 * 1024);
    const auto document = Json::parse(data);
    Require(document.is_object() && Get(document, "OPENAI_API_KEY").is_null());
    const auto mode = Get(document, "auth_mode");
    Require(mode.is_null() || mode == "chatgpt");
    const auto tokens = Get(document, "tokens");
    Require(tokens.is_object());
    const auto idToken = Text(Get(tokens, "id_token"));
    const auto accessToken = Text(Get(tokens, "access_token"));
    Require(idToken && accessToken && Text(Get(tokens, "refresh_token")));
    const auto idClaims = Claims(*idToken), accessClaims = Claims(*accessToken);
    const auto idAuth = Get(idClaims, kAuthNamespace), accessAuth = Get(accessClaims, kAuthNamespace);
    userId = Identity({Get(idAuth, "chatgpt_user_id"), Get(idAuth, "user_id"),
                       Get(accessAuth, "chatgpt_user_id"), Get(accessAuth, "user_id")});
    workspaceId = Identity({Get(tokens, "account_id"), Get(idAuth, "chatgpt_account_id"),
                            Get(accessAuth, "chatgpt_account_id")});
    const auto address = Text(Get(idClaims, "email"));
    Require(address && address->size() <= 320);
    email = *address;
    const auto profile = Get(accessClaims, "https://api.openai.com/profile");
    if (profile.is_object() && profile.contains("email")) {
      const auto other = Text(profile.at("email"));
      Require(other && Lower(*other) == Lower(email));
    }
    for (const auto& claims : {idAuth, accessAuth}) {
      try {
        const auto value = Text(Get(claims, "chatgpt_plan_type"));
        if (value) { plan = *value; break; }
      } catch (const Failure&) { /* Optional display metadata is not a login identity. */ }
    }
    rendererOwnerKey = Digest(Json::array({userId, workspaceId}).dump());
    id = "codex-" + rendererOwnerKey;
  } catch (...) { throw Failure(FailureCode::invalidCredential); }
}

Json Credential::Summary(bool current) const {
  return {{"id", id}, {"email", email}, {"workspaceId", workspaceId},
          {"plan", plan}, {"isCurrent", current}};
}

AuthPolicy::AuthPolicy(const Json& configuration) {
  Require(Get(configuration, "cli_auth_credentials_store") == "file", FailureCode::unsupportedStore);
  const auto method = Get(configuration, "forced_login_method");
  Require(method.is_null() || method == "chatgpt", FailureCode::restricted);
  const auto workspace = Get(configuration, "forced_chatgpt_workspace_id");
  Require(workspace.is_null() || workspace.is_string(), FailureCode::restricted);
  if (workspace.is_string()) workspace_ = workspace.get<std::string>();
}

void AuthPolicy::Validate(const std::string& workspace) const {
  Require(!workspace_ || *workspace_ == workspace, FailureCode::restricted);
}

std::vector<std::string> AuthPolicy::LoginOverrides() const {
  std::vector<std::string> values = {"cli_auth_credentials_store=\"file\"", "forced_login_method=\"chatgpt\""};
  if (workspace_) values.push_back("forced_chatgpt_workspace_id=" + Json(*workspace_).dump());
  return values;
}

std::optional<std::string> LocalSettings::ActiveOwner(const std::string& data) {
  try {
    const auto document = SettingsDocument(data);
    if (!document.contains(kRenderer)) return std::nullopt;
    const auto& metadata = document.at(kRenderer);
    Require(metadata.is_object() && metadata.contains("owner"), FailureCode::settingsUnavailable);
    const auto& owner = metadata.at("owner");
    if (owner.is_null()) return std::nullopt;
    Require(owner.is_string(), FailureCode::settingsUnavailable);
    return owner.get<std::string>();
  } catch (...) { throw Failure(FailureCode::settingsUnavailable); }
}

std::string LocalSettings::Transfer(const std::string& data,
    const std::optional<Credential>& source, const Credential& target) {
  try {
    auto document = SettingsDocument(data);
    if (!document.contains(kRenderer)) return data;
    auto& metadata = document.at(kRenderer);
    Require(metadata.is_object() && metadata.contains("owner") &&
        (metadata.at("owner").is_null() || metadata.at("owner").is_string()) &&
        metadata.contains("inactive") && metadata.at("inactive").is_object(), FailureCode::settingsUnavailable);
    auto& inactive = metadata.at("inactive");
    for (const auto& entry : inactive.items()) {
      Require(entry.value().is_object() && Get(entry.value(), "atoms").is_object() &&
          Get(entry.value(), "globals").is_object(), FailureCode::settingsUnavailable);
    }
    const auto owner = metadata.at("owner");
    if (!source) {
      Require(owner.is_null() && inactive.empty(), FailureCode::settingsUnavailable);
      return data;
    }
    Json sourceAtoms, sourceGlobals;
    if (owner.is_string()) {
      Require(owner == source->rendererOwnerKey, FailureCode::settingsUnavailable);
      sourceAtoms = document.value(kAtoms, Json::object());
      Require(sourceAtoms.is_object(), FailureCode::settingsUnavailable);
      sourceGlobals = document;
    } else {
      Require(inactive.contains(source->rendererOwnerKey), FailureCode::settingsUnavailable);
      sourceAtoms = inactive.at(source->rendererOwnerKey).at("atoms");
      sourceGlobals = inactive.at(source->rendererOwnerKey).at("globals");
    }
    if (source->rendererOwnerKey == target.rendererOwnerKey) return data;
    const bool existed = inactive.contains(target.rendererOwnerKey);
    const auto previous = existed ? inactive.at(target.rendererOwnerKey) :
        Json{{"atoms", Json::object()}, {"globals", Json::object()}};
    auto snapshot = previous;
    auto& atoms = snapshot.at("atoms");
    auto& globals = snapshot.at("globals");
    for (auto entry = atoms.begin(); entry != atoms.end();) {
      if (LocalAtom(entry.key())) entry = atoms.erase(entry); else ++entry;
    }
    for (const auto& entry : sourceAtoms.items()) if (LocalAtom(entry.key())) atoms[entry.key()] = entry.value();
    for (const auto& key : kLocalGlobals) {
      globals.erase(key);
      if (sourceGlobals.contains(key)) globals[key] = sourceGlobals.at(key);
    }
    if ((existed && snapshot == previous) || (!existed && atoms.empty() && globals.empty())) return data;
    inactive[target.rendererOwnerKey] = std::move(snapshot);
    const auto output = document.dump();
    Require(output.size() <= maximumBytes, FailureCode::settingsUnavailable);
    return output;
  } catch (...) { throw Failure(FailureCode::settingsUnavailable); }
}
}  // namespace loongpass::codex
