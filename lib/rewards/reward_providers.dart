import 'lobsterai_provider.dart';
import 'loomy_provider.dart';
import 'reward_provider.dart';

/// Register each protocol once. Workspace metadata, pages and owners derive
/// from this list; platform protocols never depend on navigation or widgets.
final rewardProviders = List<RewardProvider>.unmodifiable([
  LobsterAIProvider(),
  LoomyProvider(),
]);
