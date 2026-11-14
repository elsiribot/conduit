import 'dart:io';
import 'package:flutter/services.dart';

/// Reads the app's own cumulative wire bytes (rx/tx since device boot) from
/// Android's per-UID TrafficStats. Returns null wherever the numbers are
/// unavailable so callers degrade gracefully.
class TrafficStatsReader {
  static const _channel = MethodChannel('app.conduit.wallet.eric/traffic');

  static Future<({int rx, int tx})?> read() async {
    if (!Platform.isAndroid) return null;

    try {
      final stats = await _channel.invokeMapMethod<String, int>(
        'getTrafficStats',
      );

      final rx = stats?['rx'];
      final tx = stats?['tx'];

      // TrafficStats.UNSUPPORTED is -1.
      if (rx == null || tx == null || rx < 0 || tx < 0) return null;

      return (rx: rx, tx: tx);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
