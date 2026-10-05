import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'spring_drawer.dart';

const double _kFeedbackExtent = 460;

/// Shown once a trip completes (the bus reaches its final stop) — see
/// [AppState.tripJustCompleted] for the detection and dedup logic. Mirrors
/// [CollabModal]'s drawer/glass treatment so it reads as the same app.
class FeedbackModal extends StatelessWidget {
  const FeedbackModal({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return IgnorePointer(
      ignoring: !state.feedbackOpen,
      child: SpringDrawer(
        open: state.feedbackOpen,
        axis: DrawerAxis.vertical,
        extent: _kFeedbackExtent,
        builder: (context, offset, scrimOpacity) {
          return Stack(
            children: [
              if (scrimOpacity > 0)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: state.closeFeedback,
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.32 * scrimOpacity),
                    ),
                  ),
                ),
              Positioned(
                left: 0,
                right: 0,
                bottom: -offset,
                child: _FeedbackSheet(state: state, c: c),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FeedbackSheet extends StatefulWidget {
  final AppState state;
  final AppColors c;
  const _FeedbackSheet({required this.state, required this.c});

  @override
  State<_FeedbackSheet> createState() => _FeedbackSheetState();
}

class _FeedbackSheetState extends State<_FeedbackSheet> {
  int _rating = 0;
  final _commentCtrl = TextEditingController();

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final c = widget.c;

    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          boxShadow: c.sheetShadow,
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              color: c.glass,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 38,
                      height: 5,
                      margin: const EdgeInsets.only(bottom: 18),
                      decoration: BoxDecoration(
                        color: c.lab3,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: c.accSoft,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.flag_circle_rounded, size: 20, color: c.acc),
                      ),
                      const SizedBox(width: 13),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "You've arrived",
                              style: sfText(
                                size: 22,
                                weight: FontWeight.w700,
                                letterSpacing: -0.53,
                                color: c.label,
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              'How was your trip on Route ${state.detail?.number ?? ''}?',
                              style: sfText(
                                size: 14,
                                weight: FontWeight.w400,
                                color: c.lab2,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 1; i <= 5; i++)
                        GestureDetector(
                          onTap: () => setState(() => _rating = i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Icon(
                              i <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                              size: 36,
                              color: i <= _rating ? const Color(0xFFFF9F0A) : c.lab3,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Container(
                    decoration: BoxDecoration(
                      color: c.bgEl,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: TextField(
                      controller: _commentCtrl,
                      maxLines: 3,
                      maxLength: 500,
                      style: sfText(size: 14.5, weight: FontWeight.w400, color: c.label),
                      decoration: InputDecoration(
                        hintText: 'Anything you\'d like to add? (optional)',
                        hintStyle: sfText(size: 14.5, weight: FontWeight.w400, color: c.lab3),
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                        counterStyle: sfText(size: 11, weight: FontWeight.w400, color: c.lab3),
                      ),
                    ),
                  ),
                  if (state.feedbackError != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      state.feedbackError!,
                      style: sfText(size: 13, weight: FontWeight.w500, color: const Color(0xFFE5484D)),
                    ),
                  ],
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: Material(
                      color: _rating == 0 ? c.fill : c.acc,
                      borderRadius: BorderRadius.circular(15),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(15),
                        onTap: _rating == 0 || state.feedbackSubmitting
                            ? null
                            : () => state.submitFeedback(
                                  rating: _rating,
                                  comment: _commentCtrl.text.trim().isEmpty
                                      ? null
                                      : _commentCtrl.text.trim(),
                                ),
                        child: Center(
                          child: state.feedbackSubmitting
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : Text(
                                  'Submit',
                                  style: sfText(
                                    size: 17,
                                    weight: FontWeight.w600,
                                    letterSpacing: -0.17,
                                    color: _rating == 0 ? c.lab3 : Colors.white,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: state.feedbackSubmitting ? null : state.closeFeedback,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'Not now',
                          style: sfText(size: 14, weight: FontWeight.w500, color: c.lab2),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
