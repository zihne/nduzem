import 'package:flutter/material.dart';

/// Centers and caps a screen's main content column at a comfortable
/// reading width on wide viewports (desktop web).
///
/// - Small viewports (≤ [maxWidth]): fills the available width, so
///   mobile is unchanged.
/// - Wide viewports (> [maxWidth]): centers a fixed-width column of
///   [maxWidth] pixels. The AppBar (which lives on the surrounding
///   [Scaffold]) still stretches full width — only the body content
///   inside is constrained.
///
/// 720 was picked as the default because it matches the "readable
/// line length" that most Material web apps land on (Gmail, GitHub
/// settings, Firebase console) and keeps form fields at a size that
/// doesn't feel comically wide next to their labels.
class MaxWidthContent extends StatelessWidget {
  const MaxWidthContent({
    super.key,
    required this.child,
    this.maxWidth = 720,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
