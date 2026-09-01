import 'package:brother_native_print/brother_native_print.dart';
import 'package:flutter/material.dart';

import '../services/printer_controller.dart';

/// The main demo screen.
///
/// It is a thin presentation layer over [PrinterController]: it renders the
/// controller's state and forwards user actions to it, with no plugin logic
/// of its own.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late final PrinterController _controller;

  @override
  void initState() {
    super.initState();
    _controller = PrinterController()..start();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        final controller = _controller;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Brother Native Print demo'),
            actions: [
              IconButton(
                tooltip: controller.searching
                    ? 'Stop search'
                    : 'Search printers',
                onPressed: controller.busy
                    ? null
                    : (controller.searching
                          ? controller.stopSearch
                          : () => _promptSearchChannels(context)),
                icon: controller.searching
                    ? const Icon(Icons.stop)
                    : const Icon(Icons.search),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _StatusRow(state: controller.state),
                const SizedBox(height: 12),
                Expanded(child: _PrinterList(controller: controller)),
                const SizedBox(height: 12),
                _ActionButtons(controller: controller),
                const SizedBox(height: 12),
                Expanded(child: _LogView(log: controller.log)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Asks which channels to scan (Wi-Fi, Bluetooth, USB) and starts discovery.
  Future<void> _promptSearchChannels(BuildContext context) async {
    final selected = await showDialog<Set<BrotherConnectionType>>(
      context: context,
      builder: (context) => const _ChannelPickerDialog(),
    );
    if (selected == null || selected.isEmpty) return;
    await _controller.discover(connectionTypes: selected);
  }
}

/// Lets the user pick which discovery channels to scan.
class _ChannelPickerDialog extends StatefulWidget {
  const _ChannelPickerDialog();

  @override
  State<_ChannelPickerDialog> createState() => _ChannelPickerDialogState();
}

class _ChannelPickerDialogState extends State<_ChannelPickerDialog> {
  final Set<BrotherConnectionType> _selected = {
    BrotherConnectionType.wifi,
    BrotherConnectionType.bluetooth,
    BrotherConnectionType.usb,
  };

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Search printers'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final type in BrotherConnectionType.values)
            CheckboxListTile(
              value: _selected.contains(type),
              onChanged: (checked) {
                setState(() {
                  if (checked == true) {
                    _selected.add(type);
                  } else {
                    _selected.remove(type);
                  }
                });
              },
              title: Text(type.name),
              secondary: Icon(_PrinterList._iconFor(type)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop(_selected),
          child: const Text('Search'),
        ),
      ],
    );
  }
}

/// A single line reporting the current connection state.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.state});

  final PrinterConnectionState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          Icons.circle,
          size: 12,
          color: switch (state) {
            PrinterConnectionState.connected => Colors.green,
            PrinterConnectionState.connecting => Colors.orange,
            PrinterConnectionState.error => Colors.red,
            PrinterConnectionState.disconnected => Colors.grey,
          },
        ),
        const SizedBox(width: 8),
        Text('Status: ${state.name}'),
      ],
    );
  }
}

/// The list of discovered printers, with connect/disconnect actions.
class _PrinterList extends StatelessWidget {
  const _PrinterList({required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    final printers = controller.printers;
    if (printers.isEmpty) {
      return const Center(
        child: Text(
          'No printers found.\n'
          'Tap the search icon to scan.',
        ),
      );
    }
    return ListView.builder(
      itemCount: printers.length,
      itemBuilder: (context, index) {
        final printer = printers[index];
        final selected = printer == controller.selected;
        return Card(
          color: selected ? Colors.blue.shade50 : null,
          child: ListTile(
            leading: Icon(_iconFor(printer.connectionType)),
            title: Text(
              '${printer.model.toUpperCase()} '
              '(${printer.connectionType.name})',
            ),
            subtitle: Text(
              'IP: ${printer.ipAddress ?? '-'} '
              'MAC: ${printer.macAddress ?? '-'}\n'
              'SN: ${printer.serialNumber.isNotEmpty ? printer.serialNumber : '-'}',
            ),
            trailing: selected
                ? TextButton(
                    onPressed: controller.disconnect,
                    child: const Text('Disconnect'),
                  )
                : TextButton(
                    onPressed: controller.busy
                        ? null
                        : () => controller.connect(printer),
                    child: const Text('Connect'),
                  ),
          ),
        );
      },
    );
  }

  static IconData _iconFor(BrotherConnectionType type) => switch (type) {
    BrotherConnectionType.wifi => Icons.wifi,
    BrotherConnectionType.bluetooth => Icons.bluetooth,
    BrotherConnectionType.usb => Icons.usb,
  };
}

/// The print/status/cancel actions row.
class _ActionButtons extends StatelessWidget {
  const _ActionButtons({required this.controller});

  final PrinterController controller;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      alignment: WrapAlignment.center,
      children: [
        ElevatedButton.icon(
          onPressed: controller.busy ? null : controller.printImage,
          icon: const Icon(Icons.image),
          label: const Text('Print image'),
        ),
        ElevatedButton.icon(
          onPressed: controller.busy ? null : controller.printPdf,
          icon: const Icon(Icons.picture_as_pdf),
          label: const Text('Print PDF'),
        ),
        ElevatedButton.icon(
          onPressed: controller.busy ? null : controller.queryStatus,
          icon: const Icon(Icons.monitor_heart),
          label: const Text('Status'),
        ),
        ElevatedButton.icon(
          // Enabled while printing: aborts a stuck SDK print.
          onPressed: controller.busy ? controller.cancelPrinting : null,
          icon: const Icon(Icons.stop_circle),
          label: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// The scrolling log area.
class _LogView extends StatelessWidget {
  const _LogView({required this.log});

  final String log;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Text(
          log.isEmpty ? 'Log...' : log,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}
