import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../config/env.dart';

/// A failure worth showing the user, separated from bugs.
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  /// True when retrying later could plausibly succeed — no connectivity, a
  /// timeout, or a 5xx. Drives whether the UI offers a Retry action.
  final bool retryable;

  const ApiException(this.message, {this.statusCode, this.retryable = false});

  /// The caller's session is gone; the app should return to the auth screen.
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

/// Thin HTTP client for the Convex HTTP Actions surface.
///
/// Deliberately not the Convex sync protocol: plain REST works identically on
/// Android, iOS and web with no native dependency, which matters more here
/// than sub-second push updates for a bus that reports every few seconds.
class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
      : _client = client ?? http.Client(),
        _baseUrl = (baseUrl ?? Env.apiBaseUrl).replaceAll(RegExp(r'/+$'), '');

  final http.Client _client;
  final String _baseUrl;

  static const Duration _timeout = Duration(seconds: 15);

  /// Bearer token sent with subsequent requests. Null clears it.
  String? token;

  Map<String, String> _headers({bool json = false}) => {
        if (json) 'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, String>? query,
  }) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    return _send(() => _client.get(uri, headers: _headers()));
  }

  Future<Map<String, dynamic>> post(String path, [Object? body]) async {
    final uri = Uri.parse('$_baseUrl$path');
    return _send(
      () => _client.post(
        uri,
        headers: _headers(json: true),
        body: body == null ? null : jsonEncode(body),
      ),
    );
  }

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    late http.Response response;
    try {
      response = await request().timeout(_timeout);
    } on TimeoutException {
      throw const ApiException('The server took too long to respond.',
          retryable: true);
    } on SocketException {
      throw const ApiException('No connection.', retryable: true);
    } on http.ClientException catch (e) {
      // The web build surfaces network and CORS failures as ClientException
      // rather than SocketException.
      throw ApiException(e.message.isEmpty ? 'No connection.' : e.message,
          retryable: true);
    }

    if (response.statusCode == 204 || response.body.isEmpty) {
      if (response.statusCode >= 400) {
        throw ApiException(
          'Request failed (${response.statusCode}).',
          statusCode: response.statusCode,
          retryable: response.statusCode >= 500,
        );
      }
      return const {};
    }

    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      decoded = parsed is Map<String, dynamic> ? parsed : {'value': parsed};
    } on FormatException {
      throw ApiException(
        'The server returned an unexpected response.',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }

    if (response.statusCode >= 400) {
      throw ApiException(
        decoded['error']?.toString() ?? 'Request failed (${response.statusCode}).',
        statusCode: response.statusCode,
        retryable: response.statusCode >= 500,
      );
    }

    return decoded;
  }

  void close() => _client.close();
}
