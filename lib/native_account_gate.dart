// Temporary switch for this unvalidated development candidate only.
// After Mac compilation and isolated native Keychain validation pass review,
// change this one value to true. No account, app-version or signing gate.
const nativeAccountAdaptersValidated = true;

// WorkBuddy real-account controls remain closed pending separate acceptance.
const workBuddyNativeAdapterValidated = true;

// ZCode runtime-facts integration is synthetic-only until separately accepted.
const zcodeNativeAdapterValidated = false;

// Separate persistent-access acceptance; enabling WorkBuddy UI cannot open this.
const workBuddyPersistentAccessValidated = true;

// Action-time acceptance is pending. This opens only the memory identity probe.
const workBuddyMemoryIdentityApproved = true;
