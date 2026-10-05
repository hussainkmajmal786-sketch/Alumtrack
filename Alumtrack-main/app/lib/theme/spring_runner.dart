import 'dart:math' as math;
import 'package:flutter/scheduler.dart';

/// A single interruptible, velocity-aware critically/under-damped spring,
/// ported 1:1 from the prototype's `_spring(key, from, to, opts)` —
/// same zeta/omega/stiffness/damping derivation, same 0.032s frame clamp,
/// and the same "close enough" completion threshold.
class SpringRunner {
  SpringRunner(TickerProvider vsync) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;

  double _x = 0;
  double _v = 0;
  double _to = 0;
  double _k = 0;
  double _c = 0;
  Duration? _last;

  void Function(double x)? _onUpdate;
  void Function()? _onDone;

  void stop() {
    if (_ticker.isTicking) _ticker.stop();
    _last = null;
  }

  void animateTo(
    double to, {
    required double from,
    double bounce = 0.2,
    double response = 0.36,
    double velocity = 0,
    void Function(double x)? onUpdate,
    void Function()? onDone,
  }) {
    stop();
    _onUpdate = onUpdate;
    _onDone = onDone;
    _x = from;
    _v = velocity;
    _to = to;
    final zeta = 1 - bounce;
    final w = (2 * math.pi) / response;
    _k = w * w;
    _c = 2 * zeta * w;
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    if (last == null) {
      _onUpdate?.call(_x);
      return;
    }
    var dt = (elapsed - last).inMicroseconds / 1e6;
    if (dt > 0.032) dt = 0.032;
    if (dt <= 0) return;
    _v += (-_k * (_x - _to) - _c * _v) * dt;
    _x += _v * dt;
    if ((_x - _to).abs() < 0.35 && _v.abs() < 4) {
      _x = _to;
      _onUpdate?.call(_x);
      stop();
      _onDone?.call();
      return;
    }
    _onUpdate?.call(_x);
  }

  void dispose() {
    _ticker.dispose();
  }
}
