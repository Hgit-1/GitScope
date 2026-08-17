import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gitscope_mobile/main.dart';

double contrastRatio(Color first, Color second) {
  final a = first.computeLuminance();
  final b = second.computeLuminance();
  final bright = a > b ? a : b;
  final dark = a > b ? b : a;
  return (bright + 0.05) / (dark + 0.05);
}

void main() {
  test('dark theme primary and secondary text meet WCAG AA', () {
    final theme = buildGitScopeTheme(const Color(0xFF4ADE80), Brightness.dark,
        useGoogleFonts: false);
    expect(
        contrastRatio(theme.colorScheme.onSurface, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5));
    expect(
        contrastRatio(
            theme.colorScheme.onSurfaceVariant, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5));
    expect(
        contrastRatio(
            theme.colorScheme.onSurface, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(4.5));
  });

  test('light theme primary and secondary text meet WCAG AA', () {
    final theme = buildGitScopeTheme(const Color(0xFF4ADE80), Brightness.light,
        useGoogleFonts: false);
    expect(
        contrastRatio(theme.colorScheme.onSurface, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5));
    expect(
        contrastRatio(
            theme.colorScheme.onSurfaceVariant, theme.colorScheme.surface),
        greaterThanOrEqualTo(4.5));
  });
}
