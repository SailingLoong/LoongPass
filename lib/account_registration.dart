import 'dart:math';

/// Identifies a saved-account lifetime, independent of credential rotations.
String newAccountRegistrationId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
