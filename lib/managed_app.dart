import 'package:flutter/material.dart';

/// Stable identity and presentation metadata, independent of sidebar ordering.
enum ManagedApp {
  zcode('ZCode', 'Z', Color(0xFF1664FF), '智谱 BigModel', 'CN'),
  qoderCn('Qoder CN', 'Q', Color(0xFF7554D9), '国内版', 'CN'),
  qoder('Qoder', 'Q', Color(0xFF7554D9), '海外版', 'GL'),
  minimaxCn('MiniMax CN', 'M', Color(0xFFE66B32), '国内版', 'CN'),
  minimax('MiniMax', 'M', Color(0xFFE66B32), '海外版', 'GL'),
  workbuddy('WorkBuddy', 'W', Color(0xFF168978), '国内版', 'CN'),
  traeCn('TRAE CN', 'T', Color(0xFF168978), '国内版', 'CN');

  const ManagedApp(
    this.label,
    this.monogram,
    this.color,
    this.region,
    this.regionCode,
  );
  final String label, monogram, region, regionCode;
  final Color color;
}
