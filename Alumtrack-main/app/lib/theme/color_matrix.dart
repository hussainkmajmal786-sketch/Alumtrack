/// CSS-filter-equivalent color matrices (Flutter's ColorFilter.matrix
/// operates on 0-255 channel values), used to recreate the prototype's
/// Apple-Maps-style tile treatment:
///   light: saturate(0.58) brightness(1.07) contrast(0.93)
///   dark:  invert(1) hue-rotate(180deg) saturate(0.5) brightness(0.72) contrast(1.06)
library;

import 'dart:math' as math;

typedef Mat = List<double>;

Mat _identity() => [
      1, 0, 0, 0, 0, //
      0, 1, 0, 0, 0, //
      0, 0, 1, 0, 0, //
      0, 0, 0, 1, 0, //
    ];

Mat saturateMatrix(double s) {
  return [
    0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, //
    0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0, //
    0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

Mat hueRotateMatrix(double deg) {
  final rad = deg * math.pi / 180;
  final c = math.cos(rad);
  final s = math.sin(rad);
  return [
    0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0, 0, //
    0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0, 0, //
    0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

Mat invertMatrix(double amount) {
  final a = amount;
  final o = 255 * a;
  final d = 1 - 2 * a;
  return [
    d, 0, 0, 0, o, //
    0, d, 0, 0, o, //
    0, 0, d, 0, o, //
    0, 0, 0, 1, 0, //
  ];
}

Mat brightnessMatrix(double b) {
  return [
    b, 0, 0, 0, 0, //
    0, b, 0, 0, 0, //
    0, 0, b, 0, 0, //
    0, 0, 0, 1, 0, //
  ];
}

Mat contrastMatrix(double c) {
  final o = 128 * (1 - c);
  return [
    c, 0, 0, 0, o, //
    0, c, 0, 0, o, //
    0, 0, c, 0, o, //
    0, 0, 0, 1, 0, //
  ];
}

/// Applies [next] after [base] (i.e. CSS filter order left-to-right),
/// returning the composed 4x5 matrix.
Mat composeAfter(Mat base, Mat next) {
  // Treat both as 5x5 with implicit last row [0,0,0,0,1] and multiply next*base.
  Mat to5x5(Mat m) => [...m, 0, 0, 0, 0, 1];
  final a = to5x5(next); // applied second
  final b = to5x5(base); // applied first
  final out = List<double>.filled(25, 0);
  for (var r = 0; r < 5; r++) {
    for (var c = 0; c < 5; c++) {
      double sum = 0;
      for (var k = 0; k < 5; k++) {
        sum += a[r * 5 + k] * b[k * 5 + c];
      }
      out[r * 5 + c] = sum;
    }
  }
  return out.sublist(0, 20);
}

Mat compose(List<Mat> matrices) {
  var result = _identity();
  for (final m in matrices) {
    result = composeAfter(result, m);
  }
  return result;
}

final Mat lightMapFilter = compose([
  saturateMatrix(0.58),
  brightnessMatrix(1.07),
  contrastMatrix(0.93),
]);

final Mat darkMapFilter = compose([
  invertMatrix(1),
  hueRotateMatrix(180),
  saturateMatrix(0.5),
  brightnessMatrix(0.72),
  contrastMatrix(1.06),
]);
