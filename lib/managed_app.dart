import 'package:flutter/material.dart';
import 'rewards/reward_providers.dart';

/// Stable identity and presentation metadata, independent of sidebar ordering.
/// Additional reward platforms are derived from their protocol registration.
class ManagedApp {
  const ManagedApp._(
    this.name,
    this.label,
    this.monogram,
    this.color,
    this.region,
    this.regionCode,
  );
  static const zcode = ManagedApp._(
    'zcode',
    'ZCode',
    'Z',
    Color(0xFF1664FF),
    '智谱 BigModel',
    'CN',
  );
  static const qoderCn = ManagedApp._(
    'qoderCn',
    'Qoder CN',
    'Q',
    Color(0xFF7554D9),
    '国内版',
    'CN',
  );
  static const qoder = ManagedApp._(
    'qoder',
    'Qoder',
    'Q',
    Color(0xFF7554D9),
    '海外版',
    'GL',
  );
  static const minimaxCn = ManagedApp._(
    'minimaxCn',
    'MiniMax CN',
    'M',
    Color(0xFFE66B32),
    '国内版',
    'CN',
  );
  static const minimax = ManagedApp._(
    'minimax',
    'MiniMax',
    'M',
    Color(0xFFE66B32),
    '海外版',
    'GL',
  );
  static const workbuddy = ManagedApp._(
    'workbuddy',
    'WorkBuddy',
    'W',
    Color(0xFF168978),
    '国内版',
    'CN',
  );
  static const traeCn = ManagedApp._(
    'traeCn',
    'TRAE CN',
    'T',
    Color(0xFF168978),
    '国内版',
    'CN',
  );
  static final values = List<ManagedApp>.unmodifiable([
    zcode,
    qoderCn,
    qoder,
    minimaxCn,
    minimax,
    workbuddy,
    traeCn,
    for (final provider in rewardProviders)
      ManagedApp._(
        provider.id,
        provider.label,
        provider.label.substring(0, 1),
        const Color(0xFF168978),
        provider.region,
        provider.regionCode,
      ),
  ]);
  final String name, label, monogram, region, regionCode;
  final Color color;
  int get index => values.indexOf(this);
}
