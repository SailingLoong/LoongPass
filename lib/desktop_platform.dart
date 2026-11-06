import 'package:flutter/foundation.dart';

/// Availability of the native account bridge shipped with this application.
bool get nativeAccountsSupported =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

bool get workBuddyDesktopSupported =>
    defaultTargetPlatform == TargetPlatform.macOS;
