import 'package:flutter/material.dart';
import 'package:conduit/utils/styles.dart';
import 'package:conduit/widgets/shareable_row_widget.dart';

/// Shown instead of a frozen splash when startup itself fails (database or
/// client open). There is no wallet to open yet, so there is nothing to
/// retry into — just the error, shareable for a bug report.
class StartupErrorScreen extends StatelessWidget {
  final String error;

  const StartupErrorScreen({super.key, required this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Startup Failed')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Conduit could not start.',
                style: mediumStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              ShareableRow(data: error, label: 'Error'),
            ],
          ),
        ),
      ),
    );
  }
}
