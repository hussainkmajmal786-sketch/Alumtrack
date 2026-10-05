import 'package:flutter/material.dart';

/// Text style helper mirroring the prototype's inline
/// `font:<weight> <size>px/<lineHeight> -apple-system,...` shorthand.
/// SF Pro isn't bundled, so we fall back to a locally bundled Inter Tight —
/// the same fallback the prototype itself declares — rather than fetching
/// it over the network on every launch.
TextStyle sfText({
  required double size,
  FontWeight weight = FontWeight.w400,
  double? letterSpacing,
  Color? color,
  double height = 1.2,
}) {
  return TextStyle(
    fontFamily: 'InterTight',
    fontSize: size,
    fontWeight: weight,
    letterSpacing: letterSpacing,
    color: color,
    height: height,
    fontFeatures: const [FontFeature.tabularFigures()],
  );
}

/// Renders route labels like "Kottayam ⇄ CEK Kidangoor". The bidirectional
/// arrow isn't in every fallback font chain, so it's drawn as a small
/// Material icon glyph (guaranteed to be bundled) instead of relying on
/// the Unicode character resolving on every platform.
Widget routeLabel(
  String text, {
  required TextStyle style,
  int? maxLines,
  TextOverflow? overflow,
}) {
  final parts = text.split('⇄');
  if (parts.length == 1) {
    return Text(text, maxLines: maxLines, overflow: overflow, style: style);
  }
  final spans = <InlineSpan>[];
  for (var i = 0; i < parts.length; i++) {
    if (i > 0) {
      spans.add(WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Icon(Icons.sync_alt_rounded, size: (style.fontSize ?? 14) * 0.85, color: style.color),
        ),
      ));
    }
    spans.add(TextSpan(text: parts[i]));
  }
  return Text.rich(TextSpan(style: style, children: spans), maxLines: maxLines, overflow: overflow);
}
