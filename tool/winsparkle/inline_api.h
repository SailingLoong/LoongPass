/** LoongPass custom UI bridge for pinned WinSparkle 0.9.4.
 * Call actions on the host UI thread; callbacks may run on SDK workers and must
 * copy their values and enqueue work, never re-enter this API synchronously.
 * No payload paths cross this interface. WinSparkle owns the prepared installer.
 */
typedef enum {
    WIN_SPARKLE_INLINE_CHECKING = 1,
    WIN_SPARKLE_INLINE_DOWNLOADING,
    WIN_SPARKLE_INLINE_PREPARING,
    WIN_SPARKLE_INLINE_READY,
    WIN_SPARKLE_INLINE_INSTALLING,
    WIN_SPARKLE_INLINE_UP_TO_DATE,
    WIN_SPARKLE_INLINE_ERROR
} win_sparkle_inline_event;
typedef void (__cdecl *win_sparkle_inline_callback_t)(
    win_sparkle_inline_event event, const char *version,
    size_t downloaded, size_t total, int error);
WIN_SPARKLE_API void __cdecl win_sparkle_set_inline_callback(win_sparkle_inline_callback_t callback);
WIN_SPARKLE_API int __cdecl win_sparkle_check_update_inline(int manual);
WIN_SPARKLE_API int __cdecl win_sparkle_install_prepared_update();
WIN_SPARKLE_API int __cdecl win_sparkle_skip_prepared_update();

