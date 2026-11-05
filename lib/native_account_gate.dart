// Platform availability for the current macOS application. Each integration's
// implementation and real-account acceptance are recorded in VALIDATION.md.
const nativeAccountAdaptersValidated = true;

// Official authorization, saved-account restoration and check-in are enabled.
// Desktop activation has a separate native transaction and acceptance record.
const workBuddyNativeAdapterValidated = true;

// ZCode runtime-facts integration is synthetic-only until separately accepted.
const zcodeNativeAdapterValidated = false;

// Previously authorized WorkBuddy persistence is available to the account owner.
const workBuddyPersistentAccessValidated = true;

// Identity-only flows retain their restricted transport contract.
const workBuddyMemoryIdentityApproved = true;
