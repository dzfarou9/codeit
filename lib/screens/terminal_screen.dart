import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';
import '../services/proot_engine.dart';
import '../widgets/extra_keys_row.dart';

/// TerminalScreen — Main workspace.
///
/// Hosts xterm.dart, attaches PTY streams, handles resize (SIGWINCH),
/// and shows the extra virtual key row (CTRL / ALT / ESC / arrows).
///
/// The PTY lives in native code (pty_bridge.c) and is kept alive by
/// PtyService (Foreground Service) to survive Android 12+ Phantom Process Killer.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> with WidgetsBindingObserver {
  late final Terminal _terminal;
  final TerminalController _controller = TerminalController();
  StreamSubscription<Uint8List>? _outputSub;
  bool _ptyReady = false;
  String? _error;
  bool _showExtraKeys = true;

  // Track size to debounce resize events
  int _lastCols = 80;
  int _lastRows = 24;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _terminal = Terminal(
      maxLines: 5000,
      onResize: (w, h, pw, ph) {
        // Forward PTY window size to native (SIGWINCH)
        PRootEngine.instance.resize(w, h);
      },
    );

    // xterm.dart -> PTY stdin
    _terminal.onOutput = (data) {
      PRootEngine.instance.write(Uint8List.fromList(data.codeUnits));
    };

    // Handle terminal title changes (optional)
    _terminal.onTitleChange = (title) {
      // Could update AppBar title
    };

    // PTY stdout -> xterm.dart
    _outputSub = PRootEngine.instance.output.listen(
      (bytes) {
        try {
          final text = String.fromCharCodes(bytes);
          _terminal.write(text);
        } catch (e) {
          // Binary-safe fallback: filter non-UTF8
          _terminal.write(String.fromCharCodes(bytes.where((b) => b < 128)));
        }
      },
      onError: (e) => debugPrint('[TerminalScreen] output error: $e'),
    );

    // Start PTY after first frame so we know viewport size
    WidgetsBinding.instance.addPostFrameCallback((_) => _startPty());
  }

  Future<void> _startPty() async {
    try {
      // Default size; will be corrected on layout
      final cols = _lastCols;
      final rows = _lastRows;

      final ok = await PRootEngine.instance.start(cols: cols, rows: rows);
      if (!mounted) return;
      if (ok) {
        setState(() {
          _ptyReady = true;
          _error = null;
        });
        // Nudge resize after start in case view size differs
        await Future.delayed(const Duration(milliseconds: 300));
        _notifyResize();
      } else {
        setState(() => _error = 'Failed to start Linux session. Try reinstalling rootfs.');
      }
    } catch (e, st) {
      debugPrint('[TerminalScreen] _startPty error: $e\n$st');
      if (!mounted) return;
      setState(() => _error = 'PTY error: $e');
    }
  }

  void _notifyResize() {
    final cols = _terminal.viewWidth;
    final rows = _terminal.viewHeight;
    if (cols <= 0 || rows <= 0) return;
    if (cols == _lastCols && rows == _lastRows) return;
    _lastCols = cols;
    _lastRows = rows;
    PRootEngine.instance.resize(cols, rows);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep PTY alive when backgrounded (PtyService handles it).
    // Optionally pause rendering to save battery — xterm.dart buffers.
    debugPrint('[TerminalScreen] lifecycle: $state');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outputSub?.cancel();
    // Do NOT kill PTY here — let user explicitly kill via menu,
    // or keep alive via service for quick resume.
    super.dispose();
  }

  Future<void> _killAndRestart() async {
    await PRootEngine.instance.kill();
    _terminal.write('\r\n\x1b[33m[Session terminated]\x1b[0m\r\n');
    setState(() => _ptyReady = false);
    await Future.delayed(const Duration(milliseconds: 400));
    await _startPty();
  }

  void _sendExtraKey(String seq) {
    PRootEngine.instance.write(Uint8List.fromList(seq.codeUnits));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF141419),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _ptyReady ? const Color(0xFF00E5A0) : Colors.white24,
                shape: BoxShape.circle,
                boxShadow: _ptyReady
                    ? [BoxShadow(color: const Color(0xFF00E5A0).withOpacity(0.6), blurRadius: 6)]
                    : null,
              ),
            ),
            const SizedBox(width: 8),
            const Text('codeit',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, letterSpacing: -0.3)),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _ptyReady ? 'linux' : 'starting…',
                style: const TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 0.5),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _showExtraKeys ? 'Hide extra keys' : 'Show extra keys',
            icon: Icon(_showExtraKeys ? Icons.keyboard_hide : Icons.keyboard,
                size: 20, color: Colors.white70),
            onPressed: () => setState(() => _showExtraKeys = !_showExtraKeys),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20, color: Colors.white70),
            onSelected: (v) async {
              switch (v) {
                case 'restart':
                  await _killAndRestart();
                  break;
                case 'clear':
                  _terminal.write('\x1b[2J\x1b[H');
                  break;
                case 'kill':
                  await PRootEngine.instance.kill();
                  if (mounted) setState(() => _ptyReady = false);
                  break;
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'restart', child: Text('Restart session')),
              PopupMenuItem(value: 'clear', child: Text('Clear screen')),
              PopupMenuItem(value: 'kill', child: Text('Kill session')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Error banner
          if (_error != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: const Color(0xFFFF5252).withOpacity(0.12),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 16, color: Color(0xFFFF5252)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!,
                        style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A80))),
                  ),
                  TextButton(
                    onPressed: _startPty,
                    child: const Text('Retry', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),

          // Terminal
          Expanded(
            child: Container(
              color: const Color(0xFF0A0A0A),
              child: _error != null && !_ptyReady
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.terminal, size: 32, color: Colors.white24),
                          const SizedBox(height: 12),
                          Text(_error ?? 'Session not ready',
                              style: const TextStyle(color: Colors.white54, fontSize: 13)),
                          const SizedBox(height: 16),
                          FilledButton.icon(
                            onPressed: _startPty,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('Restart'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5A0),
                              foregroundColor: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    )
                  : NotificationListener<SizeChangedLayoutNotification>(
                      onNotification: (_) {
                        // Viewport size changed — notify native for SIGWINCH
                        WidgetsBinding.instance.addPostFrameCallback((_) => _notifyResize());
                        return false;
                      },
                      child: SizeChangedLayoutNotifier(
                        child: TerminalView(
                          _terminal,
                          controller: _controller,
                          autofocus: true,
                          backgroundOpacity: 1.0,
                          textStyle: const TerminalStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 13,
                          ),
                          padding: const EdgeInsets.all(6),
                        ),
                      ),
                    ),
            ),
          ),

          // Extra keys row
          if (_showExtraKeys)
            ExtraKeysRow(
              onKey: (label, seq) {
                if (seq != null) {
                  _sendExtraKey(seq);
                } else {
                  // Special handling for CTRL / ALT chord — next key is modified
                  // For simplicity, send the raw escape sequence for the label
                  _handleChord(label);
                }
              },
              onTextInput: (text) {
                PRootEngine.instance.writeString(text);
              },
            ),
        ],
      ),
    );
  }

  // Simple chord state for CTRL/ALT — next key press is modified
  bool _ctrlHeld = false;
  bool _altHeld = false;

  void _handleChord(String label) {
    switch (label) {
      case 'CTRL':
        setState(() => _ctrlHeld = !_ctrlHeld);
        if (_ctrlHeld) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('CTRL held — next key will be Ctrl+<key>'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        break;
      case 'ALT':
        setState(() => _altHeld = !_altHeld);
        break;
      case 'ESC':
        _sendExtraKey('\x1b');
        break;
      default:
        String char = label.toLowerCase();
        if (_ctrlHeld) {
          // Ctrl+A = 0x01, etc.
          final code = char.codeUnitAt(0) - 96; // 'a' (97) -> 1
          _sendExtraKey(String.fromCharCode(code));
          setState(() => _ctrlHeld = false);
        } else if (_altHeld) {
          _sendExtraKey('\x1b$char');
          setState(() => _altHeld = false);
        } else {
          _sendExtraKey(char);
        }
    }
  }
}
