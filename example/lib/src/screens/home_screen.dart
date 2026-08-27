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
                tooltip: 'Connect by IP (Wi-Fi Direct)',
                onPressed: controller.busy
                    ? null
                    : () => _promptConnectByIp(context),
                icon: const Icon(Icons.wifi),
              ),
              IconButton(
                tooltip: controller.searching
                    ? 'Stop search'
                    : 'Search printers',
                onPressed: controller.busy
                    ? null
                    : (controller.searching
                          ? controller.stopSearch
                          : controller.discover),
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

  /// Asks for an IP address and connects directly to a Wi-Fi printer.
  Future<void> _promptConnectByIp(BuildContext context) async {
    final textController = TextEditingController();
    final ip = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Connect by IP'),
        content: TextField(
          controller: textController,
          keyboardType: TextInputType.text,
          decoration: const InputDecoration(
            labelText: 'Printer IP address',
            hintText: 'e.g. 192.168.0.1 (printer LCD: Network → IP)',
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    textController.dispose();
    if (ip == null) return;
    await _controller.connectByIp(
      ip,
      model: _controller.selected?.model ?? 'QL-820NWB',
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
              'SN: ${printer.serialNumber}',
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
