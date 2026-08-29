import 'package:flutter/material.dart';
import '../theme/spring_runner.dart';

enum DrawerAxis { vertical, horizontal }

/// Generic spring-driven slide-in overlay (used for the collaborate modal
/// and the notification slide-over), matching the prototype's
/// `_setCollab`/`_setNotif` + open/close spring pairs.
class SpringDrawer extends StatefulWidget {
  final bool open;
  final DrawerAxis axis;
  final double extent;
  final double openBounce;
  final double openResponse;
  final double closeBounce;
  final double closeResponse;
  final Widget Function(BuildContext context, double offset, double scrimOpacity) builder;

  const SpringDrawer({
    super.key,
    required this.open,
    required this.axis,
    required this.extent,
    required this.builder,
    this.openBounce = 0.16,
    this.openResponse = 0.34,
    this.closeBounce = 0,
    this.closeResponse = 0.34,
  });

  @override
  State<SpringDrawer> createState() => _SpringDrawerState();
}

class _SpringDrawerState extends State<SpringDrawer> with SingleTickerProviderStateMixin {
  late final SpringRunner _spring = SpringRunner(this);
  late double _offset = widget.open ? 0 : widget.extent;

  @override
  void didUpdateWidget(covariant SpringDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.open != widget.open) {
      _spring.animateTo(
        widget.open ? 0 : widget.extent,
        from: _offset,
        bounce: widget.open ? widget.openBounce : widget.closeBounce,
        response: widget.open ? widget.openResponse : widget.closeResponse,
        onUpdate: (v) => setState(() => _offset = v),
      );
    }
  }

  @override
  void dispose() {
    _spring.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scrimOpacity = (1 - _offset / widget.extent).clamp(0.0, 1.0);
    return widget.builder(context, _offset, scrimOpacity);
  }
}
