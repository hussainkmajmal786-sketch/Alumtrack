import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Short audio cues for the bus pulling away and coming to a stop.
///
/// The tones are synthesised here rather than shipped as asset files. That
/// is a deliberate choice: recorded engine audio would mean sourcing files
/// under someone else's licence, and a generated cue carries no such
/// baggage while still giving the rider an unmistakable "it's moving now" /
/// "it's stopped" signal. It reads as a designed UI sound, not a real
/// diesel engine — that trade is the point.
class BusSounds {
  BusSounds({AudioPlayer? player}) : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  static const int _sampleRate = 22050;

  Uint8List? _startTone;
  Uint8List? _stopTone;

  /// A rising two-tone rumble: the bus pulling away.
  Uint8List get startTone => _startTone ??= _buildTone(
        durationMs: 620,
        startHz: 90,
        endHz: 190,
      );

  /// A falling rumble settling to a low note: the bus coming to rest.
  Uint8List get stopTone => _stopTone ??= _buildTone(
        durationMs: 560,
        startHz: 180,
        endHz: 80,
      );

  Future<void> playStart() => _play(startTone);

  Future<void> playStop() => _play(stopTone);

  Future<void> _play(Uint8List wav) async {
    try {
      await _player.stop();
      await _player.play(BytesSource(wav));
    } catch (e) {
      // Audio is a nicety layered on top of tracking. A device with no
      // audio route, a denied focus request, or a browser blocking
      // un-prompted playback must never take the map down with it.
      debugPrint('[bus-sounds] playback skipped: $e');
    }
  }

  Future<void> dispose() => _player.dispose();

  /// Builds a mono 16-bit PCM WAV that glides from [startHz] to [endHz].
  ///
  /// A pure sine alone sounds like a test tone, so a half-amplitude second
  /// harmonic is mixed in to give it some body, and both ends are faded to
  /// avoid the click that an abrupt waveform edge produces.
  static Uint8List _buildTone({
    required int durationMs,
    required double startHz,
    required double endHz,
  }) {
    final sampleCount = (_sampleRate * durationMs / 1000).round();
    final samples = Int16List(sampleCount);

    // Integrate the frequency sweep rather than recomputing sin(2*pi*f*t)
    // per sample: with a changing f the latter distorts the sweep, because
    // it retroactively applies the current frequency to the whole elapsed
    // time instead of only to this instant.
    double phase = 0;

    const fadeMs = 45;
    final fadeSamples = (_sampleRate * fadeMs / 1000).round();

    for (var i = 0; i < sampleCount; i++) {
      final t = i / sampleCount;
      final freq = startHz + (endHz - startHz) * t;
      phase += 2 * math.pi * freq / _sampleRate;

      final fundamental = math.sin(phase);
      final harmonic = 0.5 * math.sin(2 * phase);
      var value = (fundamental + harmonic) / 1.5;

      // Ease in and out so the tone starts and ends silently.
      if (i < fadeSamples) {
        value *= i / fadeSamples;
      } else if (i > sampleCount - fadeSamples) {
        value *= (sampleCount - i) / fadeSamples;
      }

      samples[i] = (value * 0.45 * 32767).round().clamp(-32768, 32767);
    }

    return _wrapAsWav(samples);
  }

  /// Wraps raw PCM samples in a 44-byte canonical WAV header, so the bytes
  /// can be handed straight to a player without touching the filesystem.
  static Uint8List _wrapAsWav(Int16List samples) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = _sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;
    final dataBytes = samples.length * 2;

    final out = BytesBuilder();
    void writeAscii(String s) => out.add(s.codeUnits);
    void writeUint32(int v) =>
        out.add(Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little));
    void writeUint16(int v) =>
        out.add(Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little));

    writeAscii('RIFF');
    writeUint32(36 + dataBytes);
    writeAscii('WAVE');
    writeAscii('fmt ');
    writeUint32(16); // PCM subchunk size
    writeUint16(1); // audio format: PCM
    writeUint16(channels);
    writeUint32(_sampleRate);
    writeUint32(byteRate);
    writeUint16(blockAlign);
    writeUint16(bitsPerSample);
    writeAscii('data');
    writeUint32(dataBytes);
    out.add(samples.buffer.asUint8List(0, dataBytes));

    return out.toBytes();
  }
}
