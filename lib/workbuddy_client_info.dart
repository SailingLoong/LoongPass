/// Public metadata of the installed, verified WorkBuddy CN client and its CLI.
/// The native desktop owner verifies the bundle, signature and product first.
class WorkBuddyClientInfo {
  final String appVersion, cliVersion, applicationName;
  const WorkBuddyClientInfo._(
    this.appVersion,
    this.cliVersion,
    this.applicationName,
  );

  factory WorkBuddyClientInfo.fromNative(Object? value) {
    if (value is! Map)
      throw const FormatException('WorkBuddy client info unavailable');
    final app = value['appVersion'],
        cli = value['cliVersion'],
        name = value['applicationName'];
    if (app is! String ||
        app.length > 64 ||
        RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$').stringMatch(app) !=
            app ||
        cli is! String ||
        cli.length > 64 ||
        RegExp(
              r'^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$',
            ).stringMatch(cli) !=
            cli ||
        name != 'WorkBuddy')
      throw const FormatException('WorkBuddy client info unavailable');
    return WorkBuddyClientInfo._(app, cli, name as String);
  }

  bool get supported {
    final parsed = appVersion.split('.').map(int.tryParse).toList();
    if (parsed.any((v) => v == null)) return false;
    final version = parsed.cast<int>();
    return version[0] > 5 ||
        version[0] == 5 &&
            (version[1] > 9 || version[1] == 9 && version[2] >= 3);
  }

  String get userAgent =>
      'WorkBuddy/$appVersion $applicationName/$appVersion CLI/$cliVersion';
}
