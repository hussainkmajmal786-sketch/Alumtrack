import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// A minimal on-disk tile cache, purpose-built to avoid the GPL-licensed
/// `flutter_map_tile_caching` package (using it would require either
/// open-sourcing this app under GPL v3 or a paid proprietary license from
/// its maintainer — not something to take on silently).
///
/// This has none of that package's polish: no pre-download UI, no storage
/// quota, no expiry. What it does do is the part that actually matters for
/// a bus tracker — once a tile has been fetched over a working connection,
/// it renders instantly from disk the next time the bus (and the rider's
/// phone) passes back through the same Wi-Fi dead zone, rather than
/// showing a blank tile until connectivity returns.
///
/// Mobile-only by design: `dart:io`'s `File` and [getApplicationCacheDirectory]
/// are unavailable on Flutter web, and a browser's own HTTP cache already
/// does a version of this for web anyway.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  static Directory? _cacheDir;

  static Future<Directory> _dir() async {
    final existing = _cacheDir;
    if (existing != null) return existing;
    final base = await getApplicationCacheDirectory();
    final dir = Directory('${base.path}/map_tiles');
    await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  static String _keyFor(String url) =>
      url.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    return _CachedTileImageProvider(url: url, headers: headers);
  }
}

class _CachedTileImageProvider extends ImageProvider<_CachedTileImageProvider> {
  final String url;
  final Map<String, String> headers;
  const _CachedTileImageProvider({required this.url, required this.headers});

  @override
  Future<_CachedTileImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _CachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1,
    );
  }

  Future<ui.Codec> _load(
    _CachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes = await _fetchBytes();
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  Future<Uint8List> _fetchBytes() async {
    final dir = await CachedTileProvider._dir();
    final file = File('${dir.path}/${CachedTileProvider._keyFor(url)}.tile');

    if (await file.exists()) {
      try {
        return await file.readAsBytes();
      } catch (_) {
        // A corrupt cache entry falls through to a fresh network fetch
        // below rather than failing the tile outright.
      }
    }

    final response = await http.get(Uri.parse(url), headers: headers);
    if (response.statusCode != 200) {
      throw NetworkImageLoadException(
        statusCode: response.statusCode,
        uri: Uri.parse(url),
      );
    }

    final bytes = response.bodyBytes;
    // Best-effort write: a full disk or a permission hiccup should not turn
    // a successfully fetched tile into a failed one.
    unawaited(file.writeAsBytes(bytes).catchError((_) => file));
    return bytes;
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
