import 'package:flutter/cupertino.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../models/transfer/transfer_request.dart';
import '../providers/transfer_controller.dart';
import '../services/system_info_service.dart' show formatBytes;
import '../services/tray_service.dart';

/// Watches [TransferController] for incoming transfer requests and presents the
/// Accept/Decline dialog over whatever screen is showing. Wraps the app body so
/// a request pops even when you're not on the File Transfer page.
class TransferRequestGate extends StatefulWidget {
  const TransferRequestGate({super.key, required this.child});
  final Widget child;

  @override
  State<TransferRequestGate> createState() => _TransferRequestGateState();
}

class _TransferRequestGateState extends State<TransferRequestGate> {
  TransferController? _ctrl;
  bool _showing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = context.read<TransferController>();
    if (c != _ctrl) {
      _ctrl?.removeListener(_check);
      _ctrl = c;
      c.addListener(_check);
      _check();
    }
  }

  void _check() {
    if (!mounted || _showing) return;
    final req = _ctrl?.incomingRequest;
    if (req != null) _present(req);
  }

  Future<void> _present(IncomingTransferRequest req) async {
    _showing = true;
    // If we're minimized to the tray, surface the window so the prompt is seen.
    await TrayService.instance.showWindow();
    if (!mounted) {
      _showing = false;
      return;
    }
    final accept = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) {
        final n = req.count;
        return CupertinoAlertDialog(
          title: Text('${req.fromName} wants to send you '
              '$n file${n == 1 ? '' : 's'}'),
          content: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '${formatBytes(req.totalBytes)} total\n\n'
              '${req.files.take(5).map((f) => '• ${f.name}').join('\n')}'
              '${req.files.length > 5 ? '\n…and ${req.files.length - 5} more' : ''}',
            ),
          ),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Decline'),
            ),
            CupertinoDialogAction(
              isDefaultAction: true,
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Accept'),
            ),
          ],
        );
      },
    );
    await _ctrl?.respondToRequest(req, accept ?? false);
    _showing = false;
    // Another request may have queued while this dialog was open.
    SchedulerBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    _ctrl?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
