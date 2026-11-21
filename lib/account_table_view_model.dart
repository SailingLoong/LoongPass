import 'dart:math' as math;

import 'account_table_entry.dart';

enum AccountSort { name, expiry, claim }

enum AccountFilter {
  all('全部'),
  expiring('7 天内到期'),
  actionRequired('需操作');

  const AccountFilter(this.label);
  final String label;
}

class AccountTableViewModel {
  int page = 0, size = 10;
  AccountFilter filter = AccountFilter.all;
  String search = '';
  String? platform;
  AccountSort? sort;
  bool descending = false, favoritesOnly = false;

  void clear() {
    page = 0;
    search = '';
    platform = null;
    filter = AccountFilter.all;
    favoritesOnly = false;
  }

  bool _matches(AccountTableEntry e, DateTime now) => switch (filter) {
    AccountFilter.expiring =>
      e.nextExpiry != null &&
          e.nextExpiry!.isAfter(now) &&
          !e.nextExpiry!.isAfter(now.add(const Duration(days: 7))),
    AccountFilter.actionRequired =>
      e.attention == AccountAttention.actionRequired,
    AccountFilter.all => true,
  };

  int _compareDates(DateTime? a, DateTime? b) {
    if (a == null) return b == null ? 0 : 1;
    if (b == null) return -1;
    return descending ? b.compareTo(a) : a.compareTo(b);
  }

  List<AccountTableEntry> rows(
    List<AccountTableEntry> entries,
    bool Function(AccountTableEntry) favorite,
    DateTime now,
  ) {
    final query = search.trim().toLowerCase();
    final rows = entries
        .where(
          (e) =>
              '${e.label} ${e.identity} ${e.sourceLabel ?? ''}'
                  .toLowerCase()
                  .contains(query) &&
              (platform == null || platform == e.appId) &&
              (!favoritesOnly || favorite(e)) &&
              _matches(e, now),
        )
        .toList();
    final positions = {
      for (var i = 0; i < entries.length; i++) entries[i].id: i,
    };
    rows.sort((a, b) {
      final order = switch (sort) {
        AccountSort.name =>
          descending ? b.label.compareTo(a.label) : a.label.compareTo(b.label),
        AccountSort.expiry => _compareDates(a.nextExpiry, b.nextExpiry),
        AccountSort.claim => _compareDates(
          a.receipt?.confirmedAt,
          b.receipt?.confirmedAt,
        ),
        null => (favorite(b) ? 1 : 0).compareTo(favorite(a) ? 1 : 0),
      };
      return order != 0 ? order : positions[a.id]!.compareTo(positions[b.id]!);
    });

    return rows;
  }

  int pages(int count) => math.max(1, (count / size).ceil());
  int currentPage(int count) => math.min(page, pages(count) - 1);
  Iterable<AccountTableEntry> visible(List<AccountTableEntry> rows) =>
      rows.skip(currentPage(rows.length) * size).take(size);
}
