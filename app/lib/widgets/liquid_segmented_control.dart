import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../theme/spring_runner.dart';

/// The "liquid" segmented control from the prototype: a single thumb that
/// springs across the track (bounce 0.22, response 0.36) and stretches
/// along its direction of travel while moving, settling back to shape.
class LiquidSegmentedControl extends StatefulWidget {
  final List<String> options;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const LiquidSegmentedControl({
    super.key,
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  State<LiquidSegmentedControl> createState() => _LiquidSegmentedControlState();
}

class _LiquidSegmentedControlState extends State<LiquidSegmentedControl> with SingleTickerProviderStateMixin {
  late final SpringRunner _spring = SpringRunner(this);
  double _x = 0;
  double _stretch = 1;
  bool _ready = false;
  double _trackWidth = 0;

  @override
  void didUpdateWidget(covariant LiquidSegmentedControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sync(animate: true));
    }
  }

  void _sync({required bool animate}) {
    if (!mounted || _trackWidth <= 0) return;
    final segW = _trackWidth / widget.options.length;
    final target = segW * widget.selectedIndex;
    if (!_ready || !animate) {
      _ready = true;
      setState(() {
        _x = target;
        _stretch = 1;
      });
      return;
    }
    _spring.animateTo(
      target,
      from: _x,
      bounce: 0.22,
      response: 0.36,
      onUpdate: (v) {
        if (!mounted) return;
        final stretch = 1 + (((target - v).abs() / 900).clamp(0.0, 0.14));
        setState(() {
          _x = v;
          _stretch = stretch;
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _stretch = 1);
      },
    );
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).brightness == Brightness.dark ? AppColors.dark : AppColors.light;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_trackWidth != constraints.maxWidth) {
          _trackWidth = constraints.maxWidth;
          WidgetsBinding.instance.addPostFrameCallback((_) => _sync(animate: false));
        }
        final segW = constraints.maxWidth / widget.options.length;
        final squash = 1 - (_stretch - 1) * 0.5;
        return Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: c.fill, borderRadius: BorderRadius.circular(9)),
          child: SizedBox(
            height: 32,
            child: Stack(
              children: [
                Positioned(
                  left: _x,
                  top: 0,
                  bottom: 0,
                  width: segW,
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.diagonal3Values(_stretch, squash, 1),
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 0),
                      decoration: BoxDecoration(
                        color: c.thumb,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(
                          color: c.isDark ? Colors.white.withValues(alpha: 0.26) : Colors.black.withValues(alpha: 0.05),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(color: Colors.black.withValues(alpha: c.isDark ? 0.45 : 0.18), blurRadius: c.isDark ? 10 : 3, offset: const Offset(0, 1)),
                        ],
                      ),
                    ),
                  ),
                ),
                Row(
                  children: List.generate(widget.options.length, (i) {
                    final selected = i == widget.selectedIndex;
                    return Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => widget.onChanged(i),
                        child: Center(
                          child: Text(
                            widget.options[i],
                            style: sfText(size: 13.5, weight: FontWeight.w500, letterSpacing: 0, color: c.label).copyWith(
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
