import 'package:flutter/material.dart';

/// Extra virtual key row above the soft keyboard.
///
/// Provides: ESC, TAB, CTRL, ALT, arrows, |, -, /, etc.
/// Long-press or chord behaviour for CTRL/ALT is handled by TerminalScreen.
class ExtraKeysRow extends StatelessWidget {
  final void Function(String label, String? seq) onKey;
  final void Function(String text) onTextInput;

  const ExtraKeysRow({
    super.key,
    required this.onKey,
    required this.onTextInput,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF141419),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _Key(label: 'ESC', onTap: () => onKey('ESC', '\x1b')),
              _Key(label: 'TAB', onTap: () => onKey('TAB', '\t')),
              _Key(label: 'CTRL', onTap: () => onKey('CTRL', null), accent: true),
              _Key(label: 'ALT', onTap: () => onKey('ALT', null), accent: true),
              _Sep(),
              _Key(label: '←', onTap: () => onKey('←', '\x1b[D')),
              _Key(label: '→', onTap: () => onKey('→', '\x1b[C')),
              _Key(label: '↑', onTap: () => onKey('↑', '\x1b[A')),
              _Key(label: '↓', onTap: () => onKey('↓', '\x1b[B')),
              _Sep(),
              _Key(label: '|', onTap: () => onTextInput('|')),
              _Key(label: '-', onTap: () => onTextInput('-')),
              _Key(label: '/', onTap: () => onTextInput('/')),
              _Key(label: ':', onTap: () => onTextInput(':')),
              _Key(label: '"', onTap: () => onTextInput('"')),
              _Key(label: "'", onTap: () => onTextInput("'")),
              _Sep(),
              _Key(label: 'HOME', small: true, onTap: () => onKey('HOME', '\x1b[H')),
              _Key(label: 'END', small: true, onTap: () => onKey('END', '\x1b[F')),
              _Key(label: 'PGUP', small: true, onTap: () => onKey('PGUP', '\x1b[5~')),
              _Key(label: 'PGDN', small: true, onTap: () => onKey('PGDN', '\x1b[6~')),
              _Key(label: 'DEL', small: true, onTap: () => onKey('DEL', '\x1b[3~')),
            ],
          ),
        ),
      ),
    );
  }
}

class _Key extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool accent;
  final bool small;

  const _Key({
    required this.label,
    required this.onTap,
    this.accent = false,
    this.small = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: accent ? const Color(0xFF00E5A0).withOpacity(0.12) : const Color(0xFF1E1E24),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: small ? 10 : 12,
              vertical: 9,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: accent ? const Color(0xFF00E5A0).withOpacity(0.35) : Colors.white10,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: small ? 10 : 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: accent ? const Color(0xFF00E5A0) : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 28,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      color: Colors.white10,
    );
  }
}
