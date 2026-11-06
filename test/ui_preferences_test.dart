import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/ui_preferences.dart';
import '../lib/managed_app.dart';

void main() {
  test(
    'restart restores user ordering and independent regional favorites',
    () async {
      String? stored;
      final preferences = UiPreferences(write: (value) async => stored = value);
      preferences.reorder(5, 0);
      preferences.toggleFavorite('qoderCn/same-id');
      preferences.setPageSize('workbuddy', 5);
      preferences.setCollapsed(true);
      preferences.setTheme(ThemeMode.dark);
      await preferences.saved;
      final restored = UiPreferences(read: () async => stored);
      await restored.load();
      expect(restored.appOrder.map((a) => a.name), [
        'workbuddy',
        'zcode',
        'qoderCn',
        'qoder',
        'minimaxCn',
        'minimax',
        'traeCn',
      ]);
      expect(restored.isFavorite('qoderCn/same-id'), isTrue);
      expect(restored.isFavorite('qoder/same-id'), isFalse);
      expect(restored.pageSize('workbuddy'), 5);
      expect(restored.pageSize('qoder'), 10);
      expect(restored.collapsed, isTrue);
      expect(restored.themeMode, ThemeMode.dark);
    },
  );
  test(
    'unknown and duplicate app IDs cannot hide newly supported apps',
    () async {
      final preferences = UiPreferences(
        read: () async => jsonEncode({
          'appOrder': ['qoder', 'old-app', 'qoder', null, 'zcode'],
          'pageSizes': {'qoder': 999},
          'theme': 'invalid',
        }),
      );
      await preferences.load();
      expect(preferences.appOrder.map((a) => a.name), [
        'qoder',
        'zcode',
        'qoderCn',
        'minimaxCn',
        'minimax',
        'workbuddy',
        'traeCn',
      ]);
      expect(preferences.pageSize('qoder'), 10);
      expect(preferences.themeMode, ThemeMode.system);
      final corrupt = UiPreferences(read: () async => '{bad json');
      await corrupt.load();
      expect(corrupt.appOrder, ManagedApp.values);
      expect(corrupt.error, isNotNull);
    },
  );
  test(
    'slow writes are serialized and failed persistence can be retried',
    () async {
      final first = Completer<void>();
      var writes = 0;
      String? stored;
      var fail = false;
      final preferences = UiPreferences(
        write: (value) async {
          if (++writes == 1) await first.future;
          if (fail) throw StateError('synthetic failure');
          stored = value;
        },
      );
      preferences.reorder(5, 0);
      preferences.reorder(0, 2);
      await Future<void>.delayed(Duration.zero);
      expect(writes, 1);
      first.complete();
      await preferences.saved;
      expect((jsonDecode(stored!) as Map)['appOrder'], [
        'zcode',
        'qoderCn',
        'workbuddy',
        'qoder',
        'minimaxCn',
        'minimax',
        'traeCn',
      ]);
      fail = true;
      preferences.setCollapsed(true);
      await preferences.saved;
      expect(preferences.error, isNotNull);
      expect(preferences.collapsed, isTrue);
      fail = false;
      preferences.retrySave();
      await preferences.saved;
      expect(preferences.error, isNull);
      expect((jsonDecode(stored!) as Map)['collapsed'], true);
    },
  );
}
