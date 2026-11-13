// Included once inside winsparkle's namespace in ui.cpp. No wx UI is created.
// SDK threads and the prepared payload are owned here until joined/discarded.
namespace {
std::mutex inlineMutex;
win_sparkle_inline_callback_t inlineCallback = nullptr;
bool inlineEnabled = false, inlineClosing = false, inlineBusy = false, inlineReady = false;
Thread *inlineChecker = nullptr;
UpdateDownloader *inlineDownloader = nullptr;
Appcast inlineCandidate;
std::wstring inlineFile;

void InlineEmit(win_sparkle_inline_event event, size_t downloaded = 0, size_t total = 0, int error = 0)
{
    // Caller holds inlineMutex; callback only copies/enqueues, never re-enters.
    if (!inlineClosing && inlineCallback)
        inlineCallback(event, inlineCandidate.ShortVersionString.empty() ?
            inlineCandidate.Version.c_str() : inlineCandidate.ShortVersionString.c_str(),
            downloaded, total, error);
}
void InlineJoin(Thread *thread)
{
    if (thread) { thread->TerminateAndJoin(); delete thread; }
}
class InlineManualChecker : public ManualUpdateChecker {
    bool IsJoinable() const override { return true; }
};
class InlineAutomaticChecker : public OneShotUpdateChecker {
    bool IsJoinable() const override { return true; }
};

// Shared by the original dialog and custom UI, preserving the SDK launch path.
bool RunUpdateInstaller(const std::wstring& file, const std::string& arguments)
{
    switch (ApplicationController::UserRunInstallerCallback(file.c_str())) {
        case 0: break;
        case 1: return true;
        default: return false;
    }
    std::wstring args = AnsiToWide(arguments);
    SHELLEXECUTEINFO sei = {};
    sei.cbSize = sizeof(sei);
    sei.lpFile = file.c_str();
    sei.nShow = SW_SHOWDEFAULT;
    sei.fMask = SEE_MASK_FLAG_NO_UI;
    if (!arguments.empty()) sei.lpParameters = args.c_str();
    return ::ShellExecuteEx(&sei) != FALSE;
}
} // namespace

void InlineSetCallback(win_sparkle_inline_callback_t callback)
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    inlineEnabled = true;
    inlineCallback = callback;
}

bool InlineCheck(bool manual)
{
    Thread *checker;
    UpdateDownloader *downloader;
    {
        std::lock_guard<std::mutex> lock(inlineMutex);
        if (!inlineEnabled || inlineClosing || inlineBusy || inlineReady) return false;
        inlineBusy = true;
        checker = inlineChecker; inlineChecker = nullptr;
        downloader = inlineDownloader; inlineDownloader = nullptr;
    }
    // Never join while holding the lock needed by worker callbacks.
    InlineJoin(checker);
    InlineJoin(downloader);
    UpdateDownloader::CleanLeftovers();
    std::lock_guard<std::mutex> lock(inlineMutex);
    inlineCandidate = Appcast();
    inlineFile.clear();
    inlineChecker = manual ? static_cast<Thread*>(new InlineManualChecker()) : new InlineAutomaticChecker();
    InlineEmit(WIN_SPARKLE_INLINE_CHECKING);
    inlineChecker->Start(); // SDK signals ready before any UI callback.
    return true;
}

void InlineShutdown()
{
    Thread *checker;
    UpdateDownloader *downloader;
    {
        std::lock_guard<std::mutex> lock(inlineMutex);
        inlineClosing = true; inlineCallback = nullptr;
        checker = inlineChecker; inlineChecker = nullptr;
        downloader = inlineDownloader; inlineDownloader = nullptr;
    }
    InlineJoin(checker);
    InlineJoin(downloader);
}

bool InlineNoUpdates()
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (!inlineEnabled) return false;
    inlineBusy = false;
    InlineEmit(WIN_SPARKLE_INLINE_UP_TO_DATE);
    return true;
}

bool InlineAvailable(const Appcast& info)
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (!inlineEnabled) return false;
    if (inlineClosing) return true;
    inlineCandidate = info;
    if (!info.HasDownload() || !Settings::HasEdDSAPubKey()) {
        inlineBusy = false;
        InlineEmit(WIN_SPARKLE_INLINE_ERROR, 0, 0, 2);
        return true;
    }
    inlineDownloader = new UpdateDownloader(info);
    InlineEmit(WIN_SPARKLE_INLINE_DOWNLOADING);
    inlineDownloader->Start();
    return true;
}

bool InlineProgress(size_t downloaded, size_t total)
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (!inlineEnabled) return false;
    InlineEmit(WIN_SPARKLE_INLINE_DOWNLOADING, downloaded, total);
    return true;
}
void InlinePreparing()
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (inlineEnabled) InlineEmit(WIN_SPARKLE_INLINE_PREPARING);
}
bool InlineDownloaded(const std::wstring& file, const Appcast& info)
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (!inlineEnabled) return false;
    if (inlineClosing) return true;
    inlineCandidate = info; inlineFile = file;
    inlineBusy = false; inlineReady = true;
    InlineEmit(WIN_SPARKLE_INLINE_READY);
    return true;
}
bool InlineError(ErrorCode error)
{
    std::lock_guard<std::mutex> lock(inlineMutex);
    if (!inlineEnabled) return false;
    inlineBusy = false; inlineReady = false; inlineFile.clear();
    InlineEmit(WIN_SPARKLE_INLINE_ERROR, 0, 0, error == Err_BadSignature ? 1 : 0);
    return true;
}

bool InlineInstall()
{
    std::wstring file;
    Appcast candidate;
    UpdateDownloader *downloader;
    {
        std::lock_guard<std::mutex> lock(inlineMutex);
        if (!inlineReady || inlineClosing || inlineBusy) return false;
        inlineReady = false; inlineBusy = true;
        file = inlineFile; candidate = inlineCandidate;
        downloader = inlineDownloader; inlineDownloader = nullptr;
        InlineEmit(WIN_SPARKLE_INLINE_INSTALLING);
    }
    InlineJoin(downloader);
    try {
        // The prepared file may have waited on disk; re-use the SDK verifier.
        SignatureVerifier::VerifyEdDSASignatureValid(file, candidate.enclosure.EdDsaSignature);
        if (!ApplicationController::IsReadyToShutdown() ||
            !RunUpdateInstaller(file, candidate.enclosure.InstallerArguments))
            throw std::runtime_error("Cannot launch update installer");
        ApplicationController::RequestShutdown();
        return true;
    } catch (BadSignatureException&) {
        UpdateDownloader::CleanLeftovers();
        InlineError(Err_BadSignature);
    } catch (...) { InlineError(Err_Generic); }
    return false;
}

bool InlineSkip()
{
    UpdateDownloader *downloader;
    {
        std::lock_guard<std::mutex> lock(inlineMutex);
        if (!inlineReady || inlineClosing || inlineBusy) return false;
        Settings::WriteConfigValue("SkipThisVersion", inlineCandidate.Version);
        inlineReady = false; inlineFile.clear();
        downloader = inlineDownloader; inlineDownloader = nullptr;
    }
    InlineJoin(downloader);
    UpdateDownloader::CleanLeftovers();
    ApplicationController::NotifyUpdateSkipped();
    return true;
}
