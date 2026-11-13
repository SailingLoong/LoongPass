// LoongPass custom UI entry points. Existing C exception boundary is retained.
WIN_SPARKLE_API void __cdecl win_sparkle_set_inline_callback(win_sparkle_inline_callback_t callback)
{
    try { InlineSetCallback(callback); } CATCH_ALL_EXCEPTIONS
}
WIN_SPARKLE_API int __cdecl win_sparkle_check_update_inline(int manual)
{
    try { return InlineCheck(manual != 0) ? 1 : 0; } CATCH_ALL_EXCEPTIONS
    return 0;
}
WIN_SPARKLE_API int __cdecl win_sparkle_install_prepared_update()
{
    try { return InlineInstall() ? 1 : 0; } CATCH_ALL_EXCEPTIONS
    return 0;
}
WIN_SPARKLE_API int __cdecl win_sparkle_skip_prepared_update()
{
    try { return InlineSkip() ? 1 : 0; } CATCH_ALL_EXCEPTIONS
    return 0;
}

