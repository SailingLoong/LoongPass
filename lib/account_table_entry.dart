import 'package:flutter/widgets.dart';

import 'credit_summary.dart';
import 'claim_receipt.dart';

/// Immutable presentation snapshot. The owning platform supplies all facts and
/// explicit actions; searching, paging and opening details never perform I/O.
class AccountTableEntry {
  const AccountTableEntry({
    required this.id,
    required this.label,
    required this.identity,
    required this.balance,
    required this.status,
    required this.details,
    this.credits,
    this.expiringAmount,
    this.expiryAt,
    this.receipt,
    this.observedAt,
    this.preferenceId,
    this.sourceLabel,
    this.needsAttention = false,
    this.onActivate,
    this.onOpenDetails,
    this.notice,
    this.activationEnabled = true,
  });
  final String id, label, identity, balance, status;
  final Widget details;
  final CreditSummary? credits;
  final String? expiringAmount;
  final DateTime? expiryAt;
  final bool needsAttention, activationEnabled;
  final VoidCallback? onActivate, onOpenDetails;
  final String? notice;
  final ClaimReceipt? receipt;
  String get latestClaim => receipt?.display ?? '暂无已确认记录';
  final DateTime? observedAt;
  final String? preferenceId, sourceLabel;
  DateTime? get queriedAt => observedAt ?? credits?.observedAt;
  AccountTableEntry inApp(String appId, String appLabel) => AccountTableEntry(
    id: '$appId/$id',
    preferenceId: '$appId/$id',
    sourceLabel: appLabel,
    label: label,
    identity: identity,
    balance: balance,
    status: status,
    details: details,
    credits: credits,
    expiringAmount: expiringAmount,
    expiryAt: expiryAt,
    receipt: receipt,
    observedAt: observedAt,
    needsAttention: needsAttention,
    onActivate: onActivate,
    onOpenDetails: onOpenDetails,
    notice: notice,
    activationEnabled: activationEnabled,
  );
  DateTime? get nextExpiry =>
      expiryAt ?? upcomingCreditBatches(credits).firstOrNull?.expiresAt;
  String get upcomingExpiryText => nextExpiry == null
      ? '到期信息未知'
      : '${upcomingExpiryAmount == '—' ? '额度未知' : upcomingExpiryAmount} · ${accountDate(nextExpiry!)} 到期';
  String get upcomingExpiryAmount {
    if (expiringAmount != null) return expiringAmount!;
    final batches = upcomingCreditBatches(credits);
    if (batches.isEmpty) return '—';
    final firstExpiry = batches.first.expiresAt;
    final amount = batches
        .where((b) => b.expiresAt.isAtSameMomentAs(firstExpiry))
        .fold<num>(0, (sum, b) => sum + b.remaining);
    return '${accountPoints(amount)} 积分';
  }
}

List<CreditExpiry> upcomingCreditBatches(CreditSummary? credits) {
  final now = DateTime.now();
  return [
    for (final batch in credits?.expiring ?? <CreditExpiry>[])
      if (batch.remaining > 0 && batch.expiresAt.isAfter(now)) batch,
  ]..sort((a, b) => a.expiresAt.compareTo(b.expiresAt));
}

String accountPoints(num value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : num.parse(value.toStringAsPrecision(15)).toString();
String creditBalance(CreditSummary? summary) => summary == null
    ? '尚未查询'
    : summary.totalRemaining == null
    ? '余额未知'
    : '${accountPoints(summary.totalRemaining!)} 积分';
String accountDate(DateTime time) {
  final d = time.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)}';
}

String accountTime(DateTime time) {
  final d = time.toLocal();
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
