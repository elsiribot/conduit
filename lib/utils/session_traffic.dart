import 'package:conduit/utils/traffic_stats.dart';

/// Wraps [TrafficStatsReader] with a process-global session baseline, so
/// callers can show OS wire traffic accrued during this app session instead
/// of the raw since-boot counters TrafficStats reports.
class SessionTraffic {
  static ({int rx, int tx})? _baseline;

  /// Current absolute values plus the session delta (current − baseline).
  /// The platform channel may not be ready at the very start of main(), so
  /// the first successful read defines the session start; `session` is
  /// null until a baseline exists.
  static Future<({({int rx, int tx})? current, ({int rx, int tx})? session})>
  read() async {
    final current = await TrafficStatsReader.read();
    if (current == null) return (current: null, session: null);

    final baseline = _baseline;
    // TrafficStats resets on device reboot; a current value smaller than
    // the baseline means the counters restarted, so re-baseline instead of
    // showing negatives. This assumes platform-channel replies resolve in
    // request order, which holds today because the Kotlin handler is
    // synchronous — an async handler could reorder two in-flight reads and
    // trigger a false re-baseline.
    if (baseline == null ||
        current.rx < baseline.rx ||
        current.tx < baseline.tx) {
      _baseline = current;
      return (current: current, session: (rx: 0, tx: 0));
    }

    return (
      current: current,
      session: (rx: current.rx - baseline.rx, tx: current.tx - baseline.tx),
    );
  }
}
