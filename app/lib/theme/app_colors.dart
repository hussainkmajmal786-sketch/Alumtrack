import 'package:flutter/material.dart';

/// Color tokens ported 1:1 from the Claude Design prototype's
/// `--bg`, `--label`, `--sep` etc. CSS custom properties.
class AppColors {
  final Brightness brightness;

  const AppColors._(this.brightness);

  static const AppColors light = AppColors._(Brightness.light);
  static const AppColors dark = AppColors._(Brightness.dark);

  bool get isDark => brightness == Brightness.dark;

  Color get bg => isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);
  Color get bgEl => isDark ? const Color(0xFF1C1C1E) : const Color(0xFFFFFFFF);
  Color get bgGroup => isDark ? const Color(0xFF000000) : const Color(0xFFF2F2F7);

  Color get glass => isDark ? const Color(0xB31C1C1E) : const Color(0xB8FAFAFC);
  Color get glassThin => isDark ? const Color(0x803A3A3C) : const Color(0x8CFFFFFF);

  Color get label => isDark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
  Color get lab2 => isDark ? const Color(0x9EEBEBF5) : const Color(0x9E3C3C43);
  Color get lab3 => isDark ? const Color(0x52EBEBF5) : const Color(0x523C3C43);

  Color get sep => isDark ? const Color(0x99545458) : const Color(0x293C3C43);
  Color get fill => isDark ? const Color(0x42767680) : const Color(0x1F767680);

  Color get acc => isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);
  Color get accSoft => isDark ? const Color(0x330A84FF) : const Color(0x1F007AFF);

  Color get green => isDark ? const Color(0xFF30D158) : const Color(0xFF1E7B34);
  Color get greenBg => isDark ? const Color(0x2E30D158) : const Color(0x2934C759);

  Color get orange => isDark ? const Color(0xFFFF9F0A) : const Color(0xFF9A4E00);
  Color get orangeBg => isDark ? const Color(0x2EFF9F0A) : const Color(0x2EFF9500);

  Color get gray => isDark ? const Color(0xFF98989D) : const Color(0xFF5F5F63);
  Color get grayBg => isDark ? const Color(0x3D8E8E93) : const Color(0x298E8E93);

  Color get red => isDark ? const Color(0xFFFF453A) : const Color(0xFFD70015);

  Color get thumb => isDark ? const Color(0x24FFFFFF) : const Color(0xF5FFFFFF);

  Color get stage => isDark ? const Color(0xFF131315) : const Color(0xFFE9E7E2);
  Color get stageInk => isDark ? const Color(0x73FFFFFF) : const Color(0x80000000);

  List<BoxShadow> get shadow => isDark
      ? [
          const BoxShadow(color: Color(0x8C000000), blurRadius: 38, offset: Offset(0, 12)),
          const BoxShadow(color: Color(0x66000000), blurRadius: 8, offset: Offset(0, 2)),
        ]
      : [
          const BoxShadow(color: Color(0x1A000000), blurRadius: 34, offset: Offset(0, 10)),
          const BoxShadow(color: Color(0x0D000000), blurRadius: 8, offset: Offset(0, 2)),
        ];

  List<BoxShadow> get sheetShadow => isDark
      ? [const BoxShadow(color: Color(0x80000000), blurRadius: 40, offset: Offset(0, -14))]
      : [const BoxShadow(color: Color(0x24000000), blurRadius: 40, offset: Offset(0, -14))];
}
