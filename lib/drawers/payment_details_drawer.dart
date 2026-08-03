import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:conduit/bridge_generated.dart/client.dart';
import 'package:conduit/bridge_generated.dart/events.dart';
import 'package:conduit/widgets/drawer_shell_widget.dart';
import 'package:conduit/widgets/bordered_list_widget.dart';
import 'package:conduit/widgets/payment_summary_row_widget.dart';
import 'package:conduit/widgets/detail_row_widget.dart';
import 'package:conduit/widgets/section_header_widget.dart';
import 'package:conduit/widgets/shareable_row_widget.dart';
import 'package:conduit/utils/payment_utils.dart';
import 'package:conduit/utils/drawer_utils.dart';
import 'package:conduit/utils/currency_utils.dart';

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

  /// Timing rows: the first step anchors the timeline at its wall-clock time,
  /// every later step shows its distance from the previous one.
  List<Widget> _timingRows(List<PaymentTimelineStep> steps) {
    return [
      DetailRow(
        icon: PhosphorIconsRegular.play,
        label: steps.first.label,
        value: DateFormat('HH:mm:ss').format(
          DateTime.fromMillisecondsSinceEpoch(steps.first.timestampMs),
        ),
      ),
      for (var i = 1; i < steps.length; i++)
        DetailRow(
          icon:
              i == steps.length - 1
                  ? PhosphorIconsRegular.flagCheckered
                  : PhosphorIconsRegular.hourglassMedium,
          label: steps[i].label,
          value: '+${_duration(steps[i].timestampMs - steps[i - 1].timestampMs)}',
        ),
      DetailRow(
        icon: PhosphorIconsRegular.timer,
        label: 'Total',
        value: _duration(steps.last.timestampMs - steps.first.timestampMs),
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
              ],
            ),
            // A lone event carries no durations, so the section only appears
            // once at least two steps are on record.
            if (steps.length >= 2) ...[
              const SectionHeader(title: 'Timing'),
              BorderedList.column(children: _timingRows(steps)),
            ],
          ],
        );
      },
    );
  }
}
