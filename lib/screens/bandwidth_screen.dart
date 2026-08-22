import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:conduit/bridge_generated.dart/bandwidth.dart';
import 'package:conduit/bridge_generated.dart/factory.dart';
import 'package:conduit/utils/styles.dart';
import 'package:conduit/utils/traffic_stats.dart';
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

class _BandwidthData {
  final BandwidthStats stats;
  final Map<String, String> guardianNames;
  final ({int rx, int tx})? traffic;

  _BandwidthData(this.stats, this.guardianNames, this.traffic);
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
  late Future<_BandwidthData> _data;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_BandwidthData> _load() async {
    final stats = await bandwidthStats();
    final names = await widget.clientFactory.guardianNames();
    final traffic = await TrafficStatsReader.read();

    return _BandwidthData(stats, Map.fromEntries(
      names.map((pair) => MapEntry(pair.$1, pair.$2)),
    ), traffic);
  }

  Future<void> _refresh() async {
    final data = _load();
    setState(() => _data = data);
    await data;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bandwidth')),
      body: FutureBuilder<_BandwidthData>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      'Failed to load bandwidth stats',
                      style: mediumStyle,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      snapshot.error.toString(),
                      style: smallStyle.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => setState(() => _data = _load()),
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          return RefreshIndicator(
            onRefresh: _refresh,
            child: _buildContent(snapshot.data!),
          );
        },
      ),
    );
  }

  Widget _buildContent(_BandwidthData data) {
    final entries = data.stats.entries;

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 32),
      child: BleedColumn(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(title: 'Session'),
          BorderedList.column(children: [_buildSummaryTile(data)]),
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
                (e) => data.guardianNames[e.url] ??
                    (e.kind == 'gateway' ? 'Gateway ${e.url}' : e.url),
              ))
                _buildRowTile(row),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryTile(_BandwidthData data) {
    final entries = data.stats.entries;
    final requests = entries.fold<int>(0, (sum, e) => sum + e.requests);
    final sent = entries.fold<int>(0, (sum, e) => sum + e.bytesSent);
    final received = entries.fold<int>(0, (sum, e) => sum + e.bytesReceived);
    final since = DateTime.fromMillisecondsSinceEpoch(data.stats.sinceEpochMs);
    final uptime = DateTime.now().difference(since);

    final traffic = data.traffic;
    final osLine = traffic == null
        ? 'OS wire bytes unavailable'
        : 'OS since boot: ↑ ${_formatBytes(traffic.tx)} ↓ ${_formatBytes(traffic.rx)}';

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

  Widget _buildRowTile(_Row row) {
    return ListTile(
      contentPadding: listTilePadding,
      leading: IconChip(
        icon: row.kind == 'gateway'
            ? PhosphorIconsRegular.lightning
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

  /// Aggregate entries by [key], label rows via [label], sort by total
  /// bytes descending.
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
      ..sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
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
