import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:conduit/bridge_generated.dart/bandwidth.dart';
import 'package:conduit/bridge_generated.dart/factory.dart';
import 'package:conduit/utils/styles.dart';
import 'package:conduit/utils/session_traffic.dart';
import 'package:conduit/widgets/bleed_column_widget.dart';
import 'package:conduit/widgets/bordered_list_widget.dart';
import 'package:conduit/widgets/icon_chip_widget.dart';
import 'package:conduit/widgets/section_header_widget.dart';

class BandwidthScreen extends StatefulWidget {
  final ConduitClientFactory clientFactory;

  const BandwidthScreen({super.key, required this.clientFactory});

  @override
  State<BandwidthScreen> createState() => _BandwidthScreenState();
}

/// A single poll tick: the stats/traffic snapshot plus the moment it was
/// taken, so rate math can use the real elapsed time between ticks instead
/// of assuming the timer fires exactly on schedule.
class _Sample {
  final BandwidthStats stats;
  final ({int rx, int tx})? traffic;
  final ({int rx, int tx})? sessionTraffic;
  final DateTime at;

  _Sample(this.stats, this.traffic, this.sessionTraffic, this.at);
}

/// One aggregated row (either per method or per endpoint).
class _Row {
  final String label;
  final String kind;
  int requests = 0;
  int errors = 0;
  int bytesSent = 0;
  int bytesReceived = 0;

  _Row(this.label, this.kind);

  int get totalBytes => bytesSent + bytesReceived;
}

class _BandwidthScreenState extends State<BandwidthScreen> {
  static const _tickInterval = Duration(seconds: 1);

  Map<String, String> _guardianNames = const {};
  _Sample? _previous;
  _Sample? _current;
  Object? _error;
  Timer? _timer;
  bool _ticking = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final names = await widget.clientFactory.guardianNames();
      if (!mounted) return;
      setState(() {
        _guardianNames = Map.fromEntries(
          names.map((pair) => MapEntry(pair.$1, pair.$2)),
        );
      });
    } catch (_) {
      // Guardian names are cosmetic labels; fall back to raw URLs.
    }

    await _tick();
    if (!mounted) return;
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    if (_ticking) return;
    _ticking = true;
    try {
      final stats = await bandwidthStats();
      final traffic = await SessionTraffic.read();
      if (!mounted) return;
      setState(() {
        _previous = _current;
        _current = _Sample(
          stats,
          traffic.current,
          traffic.session,
          DateTime.now(),
        );
        _error = null;
      });
    } catch (e) {
      // Swallow tick failures and keep showing the last good data; the
      // next tick usually recovers. Only surface an error state if we've
      // never had a successful sample.
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      _ticking = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bandwidth')),
      body: _current == null
          ? (_error != null ? _buildError(_error!) : _buildLoading())
          : _buildContent(_current!),
    );
  }

  Widget _buildLoading() {
    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildError(Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text('Failed to load bandwidth stats', style: mediumStyle),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: smallStyle.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(onPressed: _tick, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(_Sample sample) {
    final entries = sample.stats.entries;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      child: BleedColumn(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Session'),
          BorderedList.column(children: [_buildSummaryTile(sample)]),
          const SizedBox(height: 16),
          const SectionHeader(title: 'By RPC Method'),
          BorderedList.column(
            children: [
              for (final row in _aggregate(
                entries,
                (e) => '${e.kind}:${e.method}',
                (e) => e.method,
              ))
                _buildRowTile(row),
            ],
          ),
          const SizedBox(height: 16),
          const SectionHeader(title: 'By Endpoint'),
          BorderedList.column(
            children: [
              for (final row in _aggregate(
                entries,
                (e) => e.url,
                (e) =>
                    _guardianNames[e.url] ??
                    (e.kind == 'gateway' ? 'Gateway ${e.url}' : e.url),
              ))
                _buildRowTile(row),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTile(_Sample sample) {
    final entries = sample.stats.entries;
    final requests = entries.fold<int>(0, (sum, e) => sum + e.requests);
    final sent = entries.fold<int>(0, (sum, e) => sum + e.bytesSent);
    final received = entries.fold<int>(0, (sum, e) => sum + e.bytesReceived);
    final since = DateTime.fromMillisecondsSinceEpoch(
      sample.stats.sinceEpochMs,
    );
    final uptime = DateTime.now().difference(since);

    final session = sample.sessionTraffic;
    String osLine;
    if (session == null) {
      osLine = 'OS session unavailable';
    } else {
      final payloadTotal = sent + received;
      final overhead = payloadTotal == 0
          ? '—'
          : _formatSignedPercent(
              (session.rx + session.tx) / payloadTotal * 100 - 100,
            );
      osLine =
          'OS session: ↑ ${_formatBytes(session.tx)} ↓ ${_formatBytes(session.rx)} '
          '($overhead overhead)';
    }

    return ListTile(
      contentPadding: listTilePadding,
      leading: const IconChip(icon: PhosphorIconsRegular.chartBar),
      title: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$requests requests · ↑ ${_formatBytes(sent)} ↓ ${_formatBytes(received)}',
            style: mediumStyle,
          ),
          Text(_buildRateLine(), style: mediumStyle),
          Text(
            'Session ${_formatDuration(uptime)} · $osLine',
            style: smallStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// The "now" line: payload and OS wire throughput computed from the
  /// actual elapsed time between the last two samples, not an assumed
  /// tick interval. Shows zeros until a second sample exists.
  String _buildRateLine() {
    final prev = _previous;
    final cur = _current;
    if (prev == null || cur == null) {
      return '↑ 0 B/s ↓ 0 B/s · 0.0 req/s';
    }

    final elapsedSeconds = cur.at.difference(prev.at).inMilliseconds / 1000.0;
    if (elapsedSeconds <= 0) {
      return '↑ 0 B/s ↓ 0 B/s · 0.0 req/s';
    }

    final prevSent = prev.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.bytesSent,
    );
    final prevReceived = prev.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.bytesReceived,
    );
    final prevRequests = prev.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.requests,
    );
    final curSent = cur.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.bytesSent,
    );
    final curReceived = cur.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.bytesReceived,
    );
    final curRequests = cur.stats.entries.fold<int>(
      0,
      (sum, e) => sum + e.requests,
    );

    final sentRate = (curSent - prevSent) / elapsedSeconds;
    final receivedRate = (curReceived - prevReceived) / elapsedSeconds;
    final requestRate = (curRequests - prevRequests) / elapsedSeconds;

    var line =
        '↑ ${_formatBytes(sentRate.round())}/s '
        '↓ ${_formatBytes(receivedRate.round())}/s · '
        '${requestRate.toStringAsFixed(1)} req/s';

    final prevTraffic = prev.traffic;
    final curTraffic = cur.traffic;
    if (prevTraffic != null && curTraffic != null) {
      final osTxRate = (curTraffic.tx - prevTraffic.tx) / elapsedSeconds;
      final osRxRate = (curTraffic.rx - prevTraffic.rx) / elapsedSeconds;
      line +=
          ' · OS ↑ ${_formatBytes(osTxRate.round())}/s '
          '↓ ${_formatBytes(osRxRate.round())}/s';
    }

    return line;
  }

  Widget _buildRowTile(_Row row) {
    return ListTile(
      contentPadding: listTilePadding,
      leading: IconChip(
        icon: row.kind == 'gateway'
            ? PhosphorIconsRegular.lightning
            : row.kind == 'web'
            ? PhosphorIconsRegular.globe
            : PhosphorIconsRegular.hardDrives,
      ),
      title: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            row.label,
            style: mediumStyle,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '${row.requests} reqs'
            '${row.errors > 0 ? ' · ${row.errors} errs' : ''}'
            ' · ↑ ${_formatBytes(row.bytesSent)}'
            ' ↓ ${_formatBytes(row.bytesReceived)}',
            style: smallStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Aggregate entries by [key], label rows via [label]. Stable sort by
  /// total bytes descending, tiebreak on label ascending, so rows with
  /// equal totals don't shuffle between ticks.
  List<_Row> _aggregate(
    List<BandwidthEntry> entries,
    String Function(BandwidthEntry) key,
    String Function(BandwidthEntry) label,
  ) {
    final rows = <String, _Row>{};

    for (final entry in entries) {
      final row = rows.putIfAbsent(
        key(entry),
        () => _Row(label(entry), entry.kind),
      );
      row.requests += entry.requests;
      row.errors += entry.errors;
      row.bytesSent += entry.bytesSent;
      row.bytesReceived += entry.bytesReceived;
    }

    final sorted = rows.values.toList()
      ..sort((a, b) {
        final byBytes = b.totalBytes.compareTo(a.totalBytes);
        if (byBytes != 0) return byBytes;
        return a.label.compareTo(b.label);
      });
    return sorted;
  }

  String _formatBytes(int bytes) {
    if (bytes < 1000) return '$bytes B';
    if (bytes < 1000000) return '${(bytes / 1000).toStringAsFixed(1)} kB';
    if (bytes < 1000000000) {
      return '${(bytes / 1000000).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1000000000).toStringAsFixed(2)} GB';
  }

  /// Signed, no-decimal percentage, e.g. "+38%" or "-4%".
  String _formatSignedPercent(double value) {
    final rounded = value.round();
    return rounded >= 0 ? '+$rounded%' : '$rounded%';
  }

  String _formatDuration(Duration duration) {
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes % 60}m';
    }
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
    return '${duration.inSeconds}s';
  }
}
