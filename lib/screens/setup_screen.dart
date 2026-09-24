import 'dart:async';
import 'package:flutter/material.dart';
import '../services/rootfs_installer.dart';
import '../utils/constants.dart';

/// SetupScreen — First-launch onboarding: download + extract Linux rootfs.
///
/// Displays:
///  • Distro picker (Ubuntu / Alpine / Debian)
///  • Real-time phase + progress bar + log
///  • Upon completion calls [onInstalled] to route to TerminalScreen
class SetupScreen extends StatefulWidget {
  final VoidCallback onInstalled;
  const SetupScreen({super.key, required this.onInstalled});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final RootfsInstaller _installer = RootfsInstaller();
  StreamSubscription<InstallProgress>? _sub;

  RootfsDistro _selected = AppConstants.defaultDistro;
  InstallPhase _phase = InstallPhase.idle;
  String _message = 'Ready to set up your Linux workspace.';
  double? _progress;
  // ignore: unused_field
  Object? _error;
  bool _installing = false;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _sub = _installer.progress.listen((p) {
      if (!mounted) return;
      setState(() {
        _phase = p.phase;
        _message = p.message;
        _progress = p.progress;
        _error = p.error;
        _log.add('[${p.phase.name}] ${p.message}');
        if (_log.length > 80) _log.removeAt(0);
      });
      if (p.phase == InstallPhase.done) {
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) widget.onInstalled();
        });
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _installer.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _installing = true;
      _error = null;
      _log.clear();
    });
    final ok = await _installer.install(_selected);
    if (!mounted) return;
    setState(() => _installing = false);
    if (!ok && _phase != InstallPhase.done) {
      // Error already emitted via stream; keep screen for retry
    }
  }

  @override
  Widget build(BuildContext context) {
    final isError = _phase == InstallPhase.error;
    final isDone = _phase == InstallPhase.done;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0F0F14), Color(0xFF0A0A0A)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                // Header
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E5A0).withOpacity(0.12),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF00E5A0).withOpacity(0.3)),
                      ),
                      child: const Icon(Icons.terminal, color: Color(0xFF00E5A0)),
                    ),
                    const SizedBox(width: 12),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('codeit',
                            style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -0.5,
                                color: Colors.white)),
                        Text('Linux workspace for Android',
                            style: TextStyle(fontSize: 12, color: Colors.white54)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Card
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141419),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Choose environment',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: Colors.white70)),
                      const SizedBox(height: 10),
                      ...AppConstants.availableDistros.map((d) {
                        final selected = d.id == _selected.id;
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: InkWell(
                            onTap: _installing ? null : () => setState(() => _selected = d),
                            borderRadius: BorderRadius.circular(12),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                              decoration: BoxDecoration(
                                color: selected
                                    ? const Color(0xFF00E5A0).withOpacity(0.10)
                                    : const Color(0xFF1E1E24),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: selected
                                      ? const Color(0xFF00E5A0).withOpacity(0.5)
                                      : Colors.white10,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    d.id == 'alpine'
                                        ? Icons.landscape
                                        : d.id == 'debian'
                                            ? Icons.memory
                                            : Icons.computer,
                                    size: 18,
                                    color: selected ? const Color(0xFF00E5A0) : Colors.white54,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(d.displayName,
                                            style: TextStyle(
                                                fontSize: 13,
                                                fontWeight: FontWeight.w600,
                                                color: selected ? Colors.white : Colors.white70)),
                                        Text('~${d.estimatedSizeMb} MB • ${d.defaultShell}',
                                            style: const TextStyle(
                                                fontSize: 11, color: Colors.white38)),
                                      ],
                                    ),
                                  ),
                                  if (selected)
                                    const Icon(Icons.check_circle,
                                        size: 18, color: Color(0xFF00E5A0)),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(height: 8),
                      const Text(
                        'Rootfs is downloaded from official distro CDNs into app private storage (Scoped Storage). No Termux app required.',
                        style: TextStyle(fontSize: 11, color: Colors.white30, height: 1.4),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Status / progress
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isError
                        ? const Color(0xFFFF5252).withOpacity(0.08)
                        : isDone
                            ? const Color(0xFF00E5A0).withOpacity(0.08)
                            : const Color(0xFF1A1A1E),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isError
                          ? const Color(0xFFFF5252).withOpacity(0.4)
                          : isDone
                              ? const Color(0xFF00E5A0).withOpacity(0.4)
                              : Colors.white10,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          _PhaseIcon(phase: _phase),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _phaseLabel(_phase),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white70,
                                  letterSpacing: 0.3),
                            ),
                          ),
                          if (_installing && _phase == InstallPhase.downloading && _progress != null)
                            Text('${(_progress! * 100).toStringAsFixed(1)}%',
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF00E5A0))),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(_message,
                          style: const TextStyle(
                              fontSize: 12, color: Colors.white60, height: 1.4)),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: LinearProgressIndicator(
                          value: _progress,
                          minHeight: 6,
                          backgroundColor: Colors.white10,
                          valueColor: AlwaysStoppedAnimation(
                            isError
                                ? const Color(0xFFFF5252)
                                : isDone
                                    ? const Color(0xFF00E5A0)
                                    : const Color(0xFF7C4DFF),
                          ),
                        ),
                      ),
                      if (_log.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          height: 90,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.35),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: SingleChildScrollView(
                            reverse: true,
                            child: Text(
                              _log.join('\n'),
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: Colors.white38,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const Spacer(),

                // Action
                if (isError)
                  FilledButton.icon(
                    onPressed: _installing ? null : _start,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry setup'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5252),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  )
                else if (isDone)
                  FilledButton.icon(
                    onPressed: widget.onInstalled,
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Open terminal'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5A0),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  )
                else
                  FilledButton.icon(
                    onPressed: _installing ? null : _start,
                    icon: _installing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.download, size: 18),
                    label: Text(_installing ? 'Setting up…' : 'Download & install ${_selected.id}'),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5A0),
                      foregroundColor: Colors.black,
                      disabledBackgroundColor: Colors.white10,
                      disabledForegroundColor: Colors.white38,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),

                const SizedBox(height: 10),
                const Text(
                  'All files stay in app private storage. Binaries execute from nativeLibraryDir (W^X compliant).',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 10, color: Colors.white24),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _phaseLabel(InstallPhase p) {
    switch (p) {
      case InstallPhase.idle:
        return 'IDLE';
      case InstallPhase.resolving:
        return 'RESOLVING';
      case InstallPhase.downloading:
        return 'DOWNLOADING ROOTFS';
      case InstallPhase.extracting:
        return 'EXTRACTING ROOTFS';
      case InstallPhase.configuring:
        return 'CONFIGURING';
      case InstallPhase.done:
        return 'READY';
      case InstallPhase.error:
        return 'ERROR';
    }
  }
}

class _PhaseIcon extends StatelessWidget {
  final InstallPhase phase;
  const _PhaseIcon({required this.phase});

  @override
  Widget build(BuildContext context) {
    switch (phase) {
      case InstallPhase.idle:
        return const Icon(Icons.hourglass_empty, size: 16, color: Colors.white38);
      case InstallPhase.resolving:
        return const SizedBox(
            width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2));
      case InstallPhase.downloading:
        return const Icon(Icons.cloud_download, size: 16, color: Color(0xFF7C4DFF));
      case InstallPhase.extracting:
        return const Icon(Icons.unarchive, size: 16, color: Color(0xFFFFAB00));
      case InstallPhase.configuring:
        return const Icon(Icons.settings, size: 16, color: Colors.white54);
      case InstallPhase.done:
        return const Icon(Icons.check_circle, size: 16, color: Color(0xFF00E5A0));
      case InstallPhase.error:
        return const Icon(Icons.error, size: 16, color: Color(0xFFFF5252));
    }
  }
}
