import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:conduit/bridge_generated.dart/client.dart';
import 'package:conduit/bridge_generated.dart/events.dart';
import 'package:conduit/widgets/drawer_shell_widget.dart';
import 'package:conduit/widgets/bordered_list_widget.dart';
import 'package:conduit/widgets/payment_summary_row_widget.dart';
import 'package:conduit/widgets/detail_row_widget.dart';
import 'package:conduit/widgets/icon_chip_widget.dart';
import 'package:conduit/widgets/shareable_row_widget.dart';
import 'package:conduit/utils/payment_utils.dart';
import 'package:conduit/utils/drawer_utils.dart';
import 'package:conduit/utils/currency_utils.dart';
import 'package:conduit/utils/styles.dart';

class PaymentDetailsDrawer extends StatefulWidget {
  final ConduitPayment event;
  final ConduitClient client;

  const PaymentDetailsDrawer({
    super.key,
    required this.event,
    required this.client,
  });

  static Future<void> show(
    BuildContext context, {
    required ConduitPayment event,
    required ConduitClient client,
  }) {
    return DrawerUtils.show(
      context: context,
      child: PaymentDetailsDrawer(event: event, client: client),
    );
  }

  @override
  State<PaymentDetailsDrawer> createState() => _PaymentDetailsDrawerState();
}

class _PaymentDetailsDrawerState extends State<PaymentDetailsDrawer> {
  late final Future<List<PaymentTimelineStep>> _timeline;
  bool _timingExpanded = false;

  @override
  void initState() {
    super.initState();
    _timeline = widget.client.paymentTimeline(
      operationId: widget.event.operationId,
    );
  }

  String _formatDateTime(int timestamp) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return DateFormat('EEEE d MMMM, HH:mm').format(dateTime);
  }

  String _sats(int amount) => '${NumberFormat('#,###').format(amount)} sat';

  /// Formats a step duration: sub-minute spans with ms resolution, longer
  /// spans (e.g. on-chain confirmation) coarsened to minutes/hours.
  static String _duration(int ms) {
    if (ms >= 3600000) {
      return '${ms ~/ 3600000}h ${(ms % 3600000) ~/ 60000}m';
    }
    if (ms >= 60000) {
      return '${ms ~/ 60000}m ${(ms % 60000) ~/ 1000}s';
    }
    return '${(ms / 1000).toStringAsFixed(2)} s';
  }

  /// Collapsed summary row: total duration with a caret to reveal the
  /// step-by-step timeline.
  Widget _timingHeader(List<PaymentTimelineStep> steps) {
    return ListTile(
      contentPadding: listTilePadding,
      leading: const IconChip(icon: PhosphorIconsRegular.timer),
      title: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _duration(steps.last.timestampMs - steps.first.timestampMs),
            style: mediumStyle,
          ),
          Text(
            'Timing',
            style: smallStyle.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      trailing: AnimatedRotation(
        turns: _timingExpanded ? 0.5 : 0,
        duration: const Duration(milliseconds: 200),
        child: Icon(
          PhosphorIconsRegular.caretDown,
          size: smallIconSize,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      onTap: () => setState(() => _timingExpanded = !_timingExpanded),
    );
  }

  /// The expanded timeline: the first step anchors at its wall-clock time,
  /// every later step shows its distance from the previous one. A failed
  /// payment ends on an amber dot, mirroring the summary row's icon.
  List<Widget> _timelineRows(List<PaymentTimelineStep> steps) {
    return [
      for (var i = 0; i < steps.length; i++)
        _TimelineRow(
          label: steps[i].label,
          time:
              i == 0
                  ? DateFormat('HH:mm:ss').format(
                    DateTime.fromMillisecondsSinceEpoch(steps[i].timestampMs),
                  )
                  : '+${_duration(steps[i].timestampMs - steps[i - 1].timestampMs)}',
          first: i == 0,
          last: i == steps.length - 1,
          dotColor:
              i == steps.length - 1 && widget.event.success == false
                  ? Colors.amber
                  : null,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final fee = event.feeSats;
    final fiat = historicalFiat(event);

    return FutureBuilder<List<PaymentTimelineStep>>(
      future: _timeline,
      builder: (context, snapshot) {
        final steps = snapshot.data ?? const [];

        return DrawerShell(
          children: [
            BorderedList.column(
              children: [
                PaymentSummaryRow(
                  paymentType: event.paymentType,
                  incoming: event.incoming,
                  status:
                      '${PaymentTypeUtils.getStatus(incoming: event.incoming, success: event.success)} · ${_formatDateTime(event.timestamp)}',
                  iconColor: event.success == false ? Colors.amber : null,
                ),
                DetailRow(
                  icon: PhosphorIconsRegular.currencyBtc,
                  label: 'Bitcoin',
                  value: _sats(event.amountSats),
                ),
                if (fiat != null)
                  DetailRow(
                    icon: PhosphorIconsRegular.currencyDollar,
                    label: fiat.currency,
                    value: fiat.amount,
                  ),
                if (fee != null)
                  DetailRow(
                    icon: PhosphorIconsRegular.network,
                    label: 'Network Fee',
                    value:
                        '${_sats(fee)} · ${(fee / event.amountSats * 100).toStringAsFixed(1)}%',
                  ),
                if (event.address != null)
                  ShareableRow(data: event.address!, label: 'Bitcoin Address'),
                if (event.txid != null)
                  ShareableRow(data: event.txid!, label: 'Bitcoin Txid'),
                if (event.preimage != null)
                  ShareableRow(data: event.preimage!, label: 'Preimage'),
                if (event.ecash != null)
                  ShareableRow(data: event.ecash!, label: 'eCash'),
                // A lone event carries no durations, so the section only
                // appears once at least two steps are on record.
                if (steps.length >= 2) ...[
                  _timingHeader(steps),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    alignment: Alignment.topCenter,
                    child:
                        _timingExpanded
                            ? Column(children: _timelineRows(steps))
                            : const SizedBox(width: double.infinity),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// One stop on the vertical timeline: a dot in the leading column (aligned
/// under the row chips above it), connected to its neighbours by line
/// segments, with the step label and its timing across the row.
class _TimelineRow extends StatelessWidget {
  final String label;
  final String time;
  final bool first;
  final bool last;
  final Color? dotColor;

  const _TimelineRow({
    required this.label,
    required this.time,
    required this.first,
    required this.last,
    this.dotColor,
  });

  // IconChip at mediumIconSize is 42px wide (28px icon + 25% padding each
  // side), so a 42px lane centres the dots under the chips above.
  static const _laneWidth = 42.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final lineColor = colorScheme.outlineVariant;

    Widget line(bool hidden) => Expanded(
      child: Container(width: 2, color: hidden ? null : lineColor),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: _laneWidth,
              child: Column(
                children: [
                  line(first),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: dotColor ?? colorScheme.primary,
                    ),
                  ),
                  line(last),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(
                  children: [
                    Expanded(child: Text(label, style: mediumStyle)),
                    Text(
                      time,
                      style: smallStyle.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
