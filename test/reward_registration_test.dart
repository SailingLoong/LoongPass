import 'package:flutter_test/flutter_test.dart';
import '../lib/managed_app.dart';
import '../lib/ui_preferences.dart';

void main() {
  test(
    'new reward channels join the workspace without dropping saved app order',
    () async {
      final preferences = UiPreferences(
        read: () async =>
            '{"appOrder":["workbuddy","zcode","qoderCn","qoder","minimaxCn","minimax","traeCn"]}',
      );
      await preferences.load();
      expect(preferences.appOrder.take(7).map((app) => app.name), [
        'workbuddy',
        'zcode',
        'qoderCn',
        'qoder',
        'minimaxCn',
        'minimax',
        'traeCn',
      ]);
      expect(preferences.appOrder.skip(7).map((app) => app.name), [
        'lobsterai',
        'loomy',
      ]);
      expect(
        ManagedApp.values.map((app) => app.name).toSet().length,
        ManagedApp.values.length,
      );
    },
  );
}
