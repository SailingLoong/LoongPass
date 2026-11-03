// Synthetic-only behavioral tests, no package dependencies or native IO.
import 'dart:convert';
import 'dart:io';
import '../lib/zcode_accounts.dart';

int passed = 0;
int failed = 0;
void check(String name, void Function() body) {
  try {
    body();
    passed++;
    stdout.writeln('PASS $name');
  } catch (error) {
    failed++;
    stderr.writeln('FAIL $name: ${error.runtimeType}');
  }
}

void equal(Object? actual, Object? expected) {
  if (actual != expected) throw StateError('Unexpected result');
}

void fails(String code, void Function() body) {
  try {
    body();
  } on AccountFailure catch (error) {
    equal(error.code, code);
    equal(error.toString(), code);
    return;
  }
  throw StateError('Expected AccountFailure');
}

AccountIdentity identity(
  String id, [
  String family = 'zai',
  String context = 'synthetic-local-context',
]) => AccountIdentity(context, family, id);

// Fixtures are independent literals for the two ordinary accounts used below.
Map<String, String> doc(String id, String version, [String family = 'zai']) => {
  'oauth:active_provider': 'synthetic-$family',
  'oauth:$family:access_token': 'synthetic-$id-$version-access',
  'oauth:$family:refresh_token': 'synthetic-$id-$version-refresh',
  'oauth:$family:user_info': 'synthetic-$id-$version-profile',
  'zcodejwttoken': 'synthetic-$id-$version-jwt',
  'account-provider:coding-plan:account:$family-individual-coding-plan:account:$id:api-key':
      'synthetic-$id-$version-coding',
  'account-provider:start-plan:account:$family-start-plan:account:$id:api-key':
      'synthetic-$id-$version-start',
};

void main() {
  for (final family in ['zai', 'bigmodel']) {
    check('$family restores target and preserves unrelated credentials', () {
      final current = doc('a', 'fresh', family)..['ssh:keep'] = 'opaque';
      final target = AccountSnapshot.capture(
        identity('b', family),
        doc('b', 'saved', family),
      );
      final next = SwitchPlan.prepare(
        identity('a', family),
        current,
        target,
      ).apply(current);
      equal(next['oauth:$family:access_token'], 'synthetic-b-saved-access');
      equal(next['oauth:active_provider'], 'synthetic-$family');
      equal(next['oauth:$family:refresh_token'], 'synthetic-b-saved-refresh');
      equal(next['oauth:$family:user_info'], 'synthetic-b-saved-profile');
      equal(next['zcodejwttoken'], 'synthetic-b-saved-jwt');
      equal(
        next['account-provider:coding-plan:account:$family-individual-coding-plan:account:b:api-key'],
        'synthetic-b-saved-coding',
      );
      equal(
        next['account-provider:start-plan:account:$family-start-plan:account:b:api-key'],
        'synthetic-b-saved-start',
      );
      equal(next['ssh:keep'], 'opaque');
      equal(
        next['account-provider:coding-plan:account:$family-individual-coding-plan:account:a:api-key'],
        'synthetic-a-fresh-coding',
      );
      equal(
        next['account-provider:start-plan:account:$family-start-plan:account:a:api-key'],
        'synthetic-a-fresh-start',
      );
      equal(next.length, 10);
      equal(current['oauth:$family:access_token'], 'synthetic-a-fresh-access');
    });
    check('$family A to B to A preserves latest rotated source', () {
      final current = doc('a', 'rotated', family);
      final plan = SwitchPlan.prepare(
        identity('a', family),
        current,
        AccountSnapshot.capture(
          identity('b', family),
          doc('b', 'saved', family),
        ),
      );
      final next = plan.apply(current);
      final restored = SwitchPlan.prepare(
        identity('b', family),
        next,
        plan.backup,
      ).apply(next);
      equal(
        restored['oauth:$family:access_token'],
        'synthetic-a-rotated-access',
      );
      equal(
        restored['oauth:$family:refresh_token'],
        'synthetic-a-rotated-refresh',
      );
    });
    check('$family selecting current account preserves fresh session', () {
      final current = doc('a', 'fresh', family);
      final plan = SwitchPlan.prepare(
        identity('a', family),
        current,
        AccountSnapshot.capture(identity('a', family), doc('a', 'old', family)),
      );
      equal(plan.isNoop, true);
      equal(
        plan.apply(current)['oauth:$family:access_token'],
        'synthetic-a-fresh-access',
      );
      fails('SourceChanged', () => plan.apply(doc('a', 'newer', family)));
    });
  }
  check('snapshot includes only seven fields', () {
    final target = doc('b', 'saved')..['unrelated:secret'] = 'do-not-copy';
    final current = doc('a', 'fresh');
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('b'), target),
    ).apply(current);
    equal(next.containsKey('unrelated:secret'), false);
  });
  check('both refreshed sessions survive A to B to A to B', () {
    final first = doc('a', 'a-prime');
    final toB = SwitchPlan.prepare(
      identity('a'),
      first,
      AccountSnapshot.capture(identity('b'), doc('b', 'old')),
    );
    final bPrime = toB.apply(first)..addAll(doc('b', 'b-prime'));
    final toA = SwitchPlan.prepare(identity('b'), bPrime, toB.backup);
    final aPrime = toA.apply(bPrime);
    equal(aPrime['oauth:zai:access_token'], 'synthetic-a-a-prime-access');
    final again = SwitchPlan.prepare(
      identity('a'),
      aPrime,
      toA.backup,
    ).apply(aPrime);
    equal(again['oauth:zai:access_token'], 'synthetic-b-b-prime-access');
    equal(again['oauth:zai:refresh_token'], 'synthetic-b-b-prime-refresh');
  });
  check('trimmed account alias is noop but context identity remains exact', () {
    final current = doc('a', 'fresh');
    final old = AccountSnapshot.capture(identity(' a '), doc('a', 'old'));
    final plan = SwitchPlan.prepare(identity('a'), current, old);
    equal(plan.isNoop, true);
    equal(
      plan.apply(current)['oauth:zai:access_token'],
      'synthetic-a-fresh-access',
    );
    final other = AccountSnapshot.capture(
      identity('b', 'zai', ' synthetic-local-context '),
      doc('b', 'saved'),
    );
    fails(
      'DifferentContext',
      () => SwitchPlan.prepare(identity('a'), current, other),
    );
  });
  check('absent optional keys remove stale target fields', () {
    const coding =
        'account-provider:coding-plan:account:zai-individual-coding-plan:account:b:api-key';
    const start =
        'account-provider:start-plan:account:zai-start-plan:account:b:api-key';
    final target = doc('b', 'saved')
      ..remove('oauth:zai:refresh_token')
      ..remove('zcodejwttoken')
      ..remove(coding)
      ..remove(start);
    final current = doc('a', 'fresh')
      ..[coding] = 'stale'
      ..[start] = 'stale';
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('b'), target),
    ).apply(current);
    for (final key in [
      'oauth:zai:refresh_token',
      'zcodejwttoken',
      coding,
      start,
    ]) {
      equal(next.containsKey(key), false);
    }
  });
  check('empty optional value remains present', () {
    final target = doc('b', 'saved')..['oauth:zai:refresh_token'] = '';
    final current = doc('a', 'fresh');
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('b'), target),
    ).apply(current);
    equal(next.containsKey('oauth:zai:refresh_token'), true);
    equal(next['oauth:zai:refresh_token'], '');
  });
  check('different context is rejected', () {
    fails(
      'DifferentContext',
      () => SwitchPlan.prepare(
        identity('a'),
        doc('a', 'fresh'),
        AccountSnapshot.capture(
          identity('b', 'zai', 'another-context'),
          doc('b', 'saved'),
        ),
      ),
    );
  });
  check('different provider family is rejected', () {
    fails(
      'DifferentFamily',
      () => SwitchPlan.prepare(
        identity('a'),
        doc('a', 'fresh'),
        AccountSnapshot.capture(
          identity('b', 'bigmodel'),
          doc('b', 'saved', 'bigmodel'),
        ),
      ),
    );
  });
  for (final key in [
    'oauth:active_provider',
    'oauth:zai:access_token',
    'oauth:zai:user_info',
  ]) {
    check('missing or empty required $key is rejected', () {
      fails(
        'MissingSessionCredential',
        () => AccountSnapshot.capture(
          identity('a'),
          doc('a', 'fresh')..remove(key),
        ),
      );
      fails(
        'MissingSessionCredential',
        () => AccountSnapshot.capture(
          identity('a'),
          doc('a', 'fresh')..[key] = '',
        ),
      );
    });
  }
  check(
    'empty unknown invalid family and malformed UTF16 identity rejected',
    () {
      for (final id in ['', 'unknown', '\ud800']) {
        fails('InvalidIdentity', () => identity(id));
      }
      fails('InvalidIdentity', () => identity('a', 'unexpected'));
      fails('InvalidIdentity', () => identity('a', 'zai', ' \uFEFF'));
      fails('InvalidIdentity', () => identity('a', 'zai', '\ud800'));
    },
  );
  check('prepare refuses a current session missing required credentials', () {
    final target = AccountSnapshot.capture(identity('b'), doc('b', 'saved'));
    fails(
      'MissingSessionCredential',
      () => SwitchPlan.prepare(
        identity('a'),
        doc('a', 'fresh')..remove('oauth:zai:access_token'),
        target,
      ),
    );
  });
  check(
    'same-size and unrelated source changes are rejected without mutation',
    () {
      final current = doc('a', 'fresh')..['keep'] = 'one';
      final plan = SwitchPlan.prepare(
        identity('a'),
        current,
        AccountSnapshot.capture(identity('b'), doc('b', 'saved')),
      );
      final changed = {...current, 'keep': 'two'};
      fails('SourceChanged', () => plan.apply(changed));
      equal(changed['keep'], 'two');
      fails('SourceChanged', () => plan.apply({...current, 'new-key': 'new'}));
    },
  );
  check('map insertion order does not create a false source change', () {
    final current = doc('a', 'fresh');
    final plan = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('b'), doc('b', 'saved')),
    );
    final reordered = Map<String, String>.fromEntries(
      current.entries.toList().reversed,
    );
    equal(
      plan.apply(reordered)['oauth:zai:access_token'],
      'synthetic-b-saved-access',
    );
  });
  check('snapshot and plan do not retain mutable map aliases', () {
    final targetDoc = doc('b', 'saved');
    final target = AccountSnapshot.capture(identity('b'), targetDoc);
    targetDoc['oauth:zai:access_token'] = 'later-mutation';
    final current = doc('a', 'fresh');
    final before = {...current};
    final plan = SwitchPlan.prepare(identity('a'), current, target);
    current['oauth:zai:access_token'] = 'later-source';
    final next = plan.apply(before);
    equal(next['oauth:zai:access_token'], 'synthetic-b-saved-access');
    next['oauth:zai:access_token'] = 'later-result';
    equal(
      plan.apply(before)['oauth:zai:access_token'],
      'synthetic-b-saved-access',
    );
  });
  check('native ECMAScript trim and URI component key semantics preserved', () {
    const encoded = "a%3Ab%2F%25%20!'()*-._~%E4%B8%AD%F0%9F%98%80";
    final target = {
      'oauth:active_provider': 'synthetic-zai',
      'oauth:zai:access_token': 'synthetic-access',
      'oauth:zai:user_info': 'synthetic-profile',
      'account-provider:coding-plan:account:zai-individual-coding-plan:account:$encoded:api-key':
          'synthetic-coding',
    };
    final current = doc('a', 'fresh');
    final snapshot = AccountSnapshot.capture(
      identity(" \uFEFFa:b/% !'()*-._~中😀\u3000"),
      target,
    );
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      snapshot,
    ).apply(current);
    equal(
      next['account-provider:coding-plan:account:zai-individual-coding-plan:account:$encoded:api-key'],
      'synthetic-coding',
    );
  });
  check('U0085 is retained in native identity', () {
    final target = doc('b', 'saved')
      ..['account-provider:coding-plan:account:zai-individual-coding-plan:account:%C2%85b%C2%85:api-key'] =
          'special';
    final current = doc('a', 'fresh');
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('\u0085b\u0085'), target),
    ).apply(current);
    equal(
      next['account-provider:coding-plan:account:zai-individual-coding-plan:account:%C2%85b%C2%85:api-key'],
      'special',
    );
  });
  check('zero-width space is retained in native identity', () {
    final target = doc('b', 'saved')
      ..['account-provider:coding-plan:account:zai-individual-coding-plan:account:%E2%80%8Bb:api-key'] =
          'special';
    final current = doc('a', 'fresh');
    final next = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('\u200bb'), target),
    ).apply(current);
    equal(
      next['account-provider:coding-plan:account:zai-individual-coding-plan:account:%E2%80%8Bb:api-key'],
      'special',
    );
  });
  check('input and merged output enforce four MiB UTF8 cap', () {
    final oversized = doc('a', 'fresh')
      ..['unrelated'] = '中' * (2 * 1024 * 1024);
    fails(
      'DocumentTooLarge',
      () => AccountSnapshot.capture(identity('a'), oversized),
    );
    final current = doc('a', 'fresh')..['unrelated'] = 'a' * (3 * 1024 * 1024);
    final target = doc('b', 'saved')
      ..['oauth:zai:access_token'] = 'b' * (2 * 1024 * 1024);
    final plan = SwitchPlan.prepare(
      identity('a'),
      current,
      AccountSnapshot.capture(identity('b'), target),
    );
    fails('DocumentTooLarge', () => plan.apply(current));
  });
  check(
    'malformed UTF16 document rejected instead of silently replacing bytes',
    () {
      fails(
        'InvalidDocument',
        () => AccountSnapshot.capture(
          identity('a'),
          doc('a', 'fresh')..['unknown'] = '\ud800',
        ),
      );
      fails(
        'InvalidDocument',
        () => AccountSnapshot.capture(
          identity('a'),
          doc('a', 'fresh')..['\ud800'] = 'value',
        ),
      );
    },
  );
  check('exact four MiB JSON is accepted and one extra byte is rejected', () {
    final current = doc('a', 'fresh')..['padding'] = '';
    final available = 4 * 1024 * 1024 - utf8.encode(jsonEncode(current)).length;
    current['padding'] = 'x' * available;
    equal(utf8.encode(jsonEncode(current)).length, 4 * 1024 * 1024);
    AccountSnapshot.capture(identity('a'), current);
    current['padding'] = '${current['padding']}x';
    fails(
      'DocumentTooLarge',
      () => AccountSnapshot.capture(identity('a'), current),
    );
  });
  check('JSON escaping contributes to document size cap', () {
    final current = doc('a', 'fresh')..['padding'] = '';
    final available = 4 * 1024 * 1024 - utf8.encode(jsonEncode(current)).length;
    current['padding'] = '\n' * (available ~/ 2) + 'x' * (available % 2);
    equal(utf8.encode(jsonEncode(current)).length, 4 * 1024 * 1024);
    AccountSnapshot.capture(identity('a'), current);
    current['padding'] = '${current['padding']}\n';
    fails(
      'DocumentTooLarge',
      () => AccountSnapshot.capture(identity('a'), current),
    );
  });
  check(
    'snapshots and plans have no credential serialization or debug output',
    () {
      final target = AccountSnapshot.capture(identity('b'), doc('b', 'saved'));
      final plan = SwitchPlan.prepare(identity('a'), doc('a', 'fresh'), target);
      equal('$target $plan'.contains('synthetic-b'), false);
      try {
        jsonEncode(target);
        throw StateError('Snapshot exposed JSON');
      } on JsonUnsupportedObjectError {
        // This opaque handle is deliberately not serializable by the UI.
      }
    },
  );
  stdout.writeln('$passed passed, $failed failed');
  if (failed != 0) exitCode = 1;
}
