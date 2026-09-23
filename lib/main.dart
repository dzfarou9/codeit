import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/proot_engine.dart';
import 'screens/setup_screen.dart';
import 'screens/terminal_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to portrait for terminal UX (optional — remove if landscape desired)
  // SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  // Edge-to-edge
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF0A0A0A),
  ));

  // Pre-init engine so nativeLibraryDir / filesDir are ready before routing
  await PRootEngine.instance.init();

  runApp(const CodeItApp());
}

class CodeItApp extends StatelessWidget {
  const CodeItApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'codeit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0A),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5A0),
          secondary: Color(0xFF7C4DFF),
          surface: Color(0xFF1A1A1E),
          error: Color(0xFFFF5252),
        ),
        useMaterial3: true,
        fontFamily: 'JetBrainsMono',
      ),
      home: const RootRouter(),
    );
  }
}

/// Decides whether to show SetupScreen or TerminalScreen
/// based on rootfs installation state.
class RootRouter extends StatefulWidget {
  const RootRouter({super.key});

  @override
  State<RootRouter> createState() => _RootRouterState();
}

class _RootRouterState extends State<RootRouter> {
  bool? _installed;
  String? _error;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    try {
      final v = await PRootEngine.instance.isInstalled();
      if (!mounted) return;
      setState(() => _installed = v);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                const SizedBox(height: 16),
                Text('Startup error:\n$_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () {
                    setState(() {
                      _error = null;
                      _installed = null;
                    });
                    _check();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (_installed == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 32,
                height: 32,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              SizedBox(height: 16),
              Text('codeit — initializing…',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
        ),
      );
    }

    // Route
    if (_installed == true) {
      return const TerminalScreen();
    } else {
      return SetupScreen(
        onInstalled: () {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const TerminalScreen()),
          );
        },
      );
    }
  }
}
