#include "codex_account_store.h"

#include <algorithm>
#include <tuple>

namespace loongpass::codex {
namespace {
void Require(bool value, FailureCode code = FailureCode::recoveryConflict) {
  if (!value) throw Failure(code);
}
std::string PathText(const std::filesystem::path& path) { return path.u8string(); }
}  // namespace

AccountStore::AccountStore(const std::filesystem::path& root) try : file_(root) {
  const auto document = file_.Read("accounts.json");
  if (document.is_null()) return;
  Require(document.value("schema", 0) == 1 && document.contains("credentials") &&
      document.at("credentials").is_object(), FailureCode::unavailable);
  for (const auto& entry : document.at("credentials").items()) {
    Require(entry.value().is_string(), FailureCode::unavailable);
    Credential credential(DecodeBase64(entry.value().get<std::string>()));
    Require(credential.id == entry.key(), FailureCode::unavailable);
    saved_.emplace(entry.key(), std::move(credential));
  }
} catch (...) { throw Failure(FailureCode::unavailable); }

void AccountStore::Save(const std::map<std::string, Credential>& accounts) {
  Json encoded = Json::object();
  for (const auto& entry : accounts) encoded[entry.first] = EncodeBase64(entry.second.data);
  try { file_.Write({{"schema", 1}, {"credentials", encoded}}, "accounts.json"); }
  catch (...) { throw Failure(FailureCode::unavailable); }
  saved_ = accounts;
}

std::string AccountStore::Capture(const std::string& data) {
  Credential value(data);
  const auto found = saved_.find(value.id);
  if (found == saved_.end() || found->second.data != data) {
    auto next = saved_;
    next.insert_or_assign(value.id, value);
    Save(next);
  }
  return value.id;
}

Credential AccountStore::Saved(const std::string& id) const {
  const auto found = saved_.find(id);
  if (found == saved_.end()) throw Failure(FailureCode::accountNotFound);
  return found->second;
}

void AccountStore::Remove(const std::string& id) {
  Require(saved_.count(id) != 0, FailureCode::accountNotFound);
  auto next = saved_;
  next.erase(id);
  Save(next);
}

void AccountStore::Observe(const std::optional<std::string>& data) {
  if (data) {
    const Credential value(*data);
    if (saved_.count(value.id) != 0) Capture(*data);
  }
}

Json AccountStore::Summaries(const std::optional<std::string>& current) const {
  std::vector<const Credential*> rows;
  for (const auto& entry : saved_) rows.push_back(&entry.second);
  std::sort(rows.begin(), rows.end(), [](const Credential* a, const Credential* b) {
    return std::tie(a->email, a->workspaceId, a->id) < std::tie(b->email, b->workspaceId, b->id);
  });
  Json result = Json::array();
  for (const auto* row : rows) result.push_back(row->Summary(current && row->id == *current));
  return result;
}

void AccountStore::Recover(AuthFile& auth, const std::function<void()>& ensureStopped) {
  auto journal = file_.Read("switch.json");
  if (journal.is_null()) return;
  Require(journal.value("schema", 0) == 1 && journal.contains("state"));
  const auto state = journal.at("state").get<std::string>();
  Require(state == "prepared" || state == "applied" || state == "aborted");
  if (state != "prepared") return;
  Require(journal.at("root") == PathText(auth.root()) && journal.at("rootRevision") == auth.RootRevision());
  const auto before = journal.at("before").get<std::string>();
  const auto after = journal.at("after").get<std::string>();
  auth.RecoverReplacement(journal.at("stage"), "auth.json", before, after, ensureStopped);
  if (journal.contains("settings")) {
    const auto& settings = journal.at("settings");
    auth.RecoverReplacement(settings.at("stage"), LocalSettings::fileName,
        settings.at("beforeDigest"), settings.at("afterDigest"), ensureStopped);
  }
  const auto current = auth.Read();
  Require(current.digest() == before || current.digest() == after);
  bool applied = current.digest() == after;
  if (journal.contains("settings")) {
    const auto& settings = journal.at("settings");
    const auto original = DecodeBase64(settings.at("before").get<std::string>());
    Require(Digest(original) == settings.at("beforeDigest"));
    const auto present = auth.Read(LocalSettings::fileName);
    const bool settingsBefore = present.digest() == settings.at("beforeDigest");
    const bool settingsAfter = present.digest() == settings.at("afterDigest");
    // The selected identity can already be in auth.json while its renderer
    // still belongs to the previous account. In that case settings distinguish
    // an untouched operation from an already-complete one.
    if (before == after) applied = settingsAfter;
    Require(applied ? settingsAfter : settingsBefore || settingsAfter);
    if (!applied && settingsAfter) {
      auth.Replace(original, present, settings.at("stage"), LocalSettings::fileName, [&] {
        ensureStopped();
        Require(auth.Read() == current);
      });
    }
    auth.DiscardStage(settings.at("stage"), settings.at("afterDigest"));
  }
  auth.DiscardStage(journal.at("stage"), after);
  journal["state"] = applied ? "applied" : "aborted";
  file_.Write(journal, "switch.json");
}

void AccountStore::Activate(const std::string& id, AuthFile& auth,
    const std::function<void()>& ensureStopped) {
  Require(saved_.count(id) != 0, FailureCode::accountNotFound);
  auth.WithExclusive([&] {
    ensureStopped();
    Recover(auth, ensureStopped);
    const auto before = auth.Read();
    std::optional<Credential> source;
    if (before.data) {
      source.emplace(*before.data);
      Capture(source->data);
    }
    // Capture first: choosing the current identity must keep its newest grant.
    const auto target = Saved(id);
    const auto preferences = auth.Read(LocalSettings::fileName);
    auto nextPreferences = preferences.data;
    if (preferences.data) {
      auto rendererSource = source;
      const auto owner = LocalSettings::ActiveOwner(*preferences.data);
      if (owner) {
        const auto known = std::find_if(saved_.begin(), saved_.end(), [&](const auto& entry) {
          return entry.second.rendererOwnerKey == *owner;
        });
        Require(known != saved_.end(), FailureCode::settingsUnavailable);
        rendererSource = known->second;
      }
      nextPreferences = LocalSettings::Transfer(*preferences.data, rendererSource, target);
    }
    const auto stage = ".loongpass-codex-auth-" + RandomHex(16);
    const auto settingsStage = ".loongpass-codex-settings-" + RandomHex(16);
    Json journal = {{"schema", 1}, {"state", "prepared"}, {"root", PathText(auth.root())},
        {"rootRevision", auth.RootRevision()}, {"before", before.digest()},
        {"after", Digest(target.data)}, {"stage", stage}};
    if (nextPreferences != preferences.data) {
      Require(preferences.data && nextPreferences, FailureCode::settingsUnavailable);
      journal["settings"] = {{"before", EncodeBase64(*preferences.data)},
          {"beforeDigest", preferences.digest()}, {"afterDigest", Digest(*nextPreferences)},
          {"stage", settingsStage}};
    }
    file_.Write(journal, "switch.json");
    try {
      if (nextPreferences != preferences.data) {
        auth.Replace(*nextPreferences, preferences, settingsStage, LocalSettings::fileName, [&] {
          ensureStopped();
          Require(auth.Read() == before, FailureCode::sourceChanged);
        });
      }
      auth.Replace(target.data, before, stage, "auth.json", [&] {
        ensureStopped();
        Require(auth.Read(LocalSettings::fileName).data == nextPreferences, FailureCode::sourceChanged);
      });
      journal["state"] = "applied";
      file_.Write(journal, "switch.json");
    } catch (...) {
      try { Recover(auth, ensureStopped); } catch (...) { /* Retain an unrecognized recovery record. */ }
      throw;
    }
  });
}
}  // namespace loongpass::codex
