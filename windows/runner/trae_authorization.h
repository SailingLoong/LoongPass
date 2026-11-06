#pragma once

#include "native_support.h"

namespace loongpass {

// Decodes the official client's existing format. The caller owns selection,
// stable file reads, installed-client discovery and Windows device facts.
Json DecodeTraeAuthorization(const Json& source, const std::string& version,
                             const Json& device_facts);
Json SignTraeRefresh(const std::string& private_pem,
                     const std::string& refresh_token);

}  // namespace loongpass
