#ifndef LOONGPASS_ZCODE_H
#define LOONGPASS_ZCODE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Native backend only. Context and secret never originate in a Flutter message.
// Callback/userdata remain valid until lp_zcode_close; do not reenter the ABI
// from the callback. Verify current context FIRST. Return 0=verified stopped,
// 1=verified current context with active writers,
// 2=context changed, 3/other=context unavailable. Never infer missing context.
typedef int32_t (*lp_zcode_gate)(void *userdata);
uint64_t lp_zcode_open(const uint8_t *config, size_t len, lp_zcode_gate gate, void *userdata);
// Returned UTF-8 JSON is owned by Rust and must be freed exactly once by free.
char *lp_zcode_call(uint64_t session, const uint8_t *request, size_t len);
void lp_zcode_close(uint64_t session);
void lp_zcode_free(char *response);
// Native-only explicit-facts entrypoints. Never exposed as Flutter methods.
// Unknown effective ZCode facts fail closed; no environment/settings discovery.
uint64_t lp_zcode_owner_open(const uint8_t *facts, size_t facts_len,
    const uint8_t *options, size_t options_len, lp_zcode_gate gate, void *userdata);
// Metadata exposes source/contextId and optional non-secret runtimeContext.
// Free with lp_zcode_free; no seed or key bytes are returned.
char *lp_zcode_owner_metadata(const uint8_t *facts, size_t len);
char *lp_zcode_owner_decide(const uint8_t *request, size_t len);
#ifdef __cplusplus
}
#endif
#endif
