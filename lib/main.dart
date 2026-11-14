import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:conduit/utils/styles.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:conduit/bridge_generated.dart/frb_generated.dart';
import 'package:conduit/bridge_generated.dart/lib.dart';
import 'package:conduit/bridge_generated.dart/logging.dart';
import 'package:conduit/bridge_generated.dart/factory.dart';
import 'package:conduit/bridge_generated.dart/bandwidth.dart';
import 'package:conduit/utils/session_traffic.dart';
import 'package:conduit/screens/landing_screen.dart';
import 'package:conduit/screens/base_screen.dart';
import 'package:conduit/screens/home_screen.dart';
import 'package:conduit/screens/startup_error_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // iOS uses static linking, Android uses dynamic library
  if (Platform.isIOS) {
    await RustLib.init(
      externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
    );
  } else {
    await RustLib.init();
  }

  final dir = await getApplicationDocumentsDirectory();

  try {
    await initLogging(appDir: dir.path);
  } catch (e) {
    debugPrint('Failed to initialize file logging: $e');
  }

  // Bandwidth snapshot logging: cheap no-op inside Rust when nothing
  // changed, so the tight cadence is safe. See the bandwidth-monitor spec.
  // Routed through SessionTraffic so the session baseline is captured
  // early even if the bandwidth screen is never opened; the log still gets
  // the absolute since-boot values, unchanged.
  Timer.periodic(const Duration(seconds: 10), (_) async {
    try {
      final traffic = await SessionTraffic.read();
      await logBandwidthSnapshot(
        osRxBytes: traffic.current?.rx,
        osTxBytes: traffic.current?.tx,
      );
    } catch (_) {
      // Logging must never break the app.
    }
  });

  try {
    final db = await openDatabase(dbPath: dir.path);

    final clientFactory = await ConduitClientFactory.tryLoad(db: db);

    if (clientFactory == null) {
      runApp(ConduitApp(home: LandingScreen(db: db)));
      return;
    }

    // Clients only connect to their guardians on demand and keep whatever
    // connection they get for as long as it stays up, so a connection that
    // died while the app was backgrounded (network change, OS-level idle
    // teardown) otherwise sits dead until something happens to use it again.
    // Nudging every client on resume reconnects immediately instead.
    AppLifecycleListener(onResume: clientFactory.reconnectAll);

    // Open every account of every mint before the first frame so the wallet
    // itself is the first thing shown (the OS splash stays up until it's
    // ready). Only an empty wallet falls back to BaseScreen, which hosts
    // onboarding; a mint still recovering opens with the rest and shows its
    // progress itself.
    final clients = await clientFactory.loadAll();
    final selected = await clientFactory.selectedClient();

    runApp(
      ConduitApp(
        home:
            clients.isEmpty
                ? BaseScreen(clientFactory: clientFactory)
                : HomeScreen(
                  clientFactory: clientFactory,
                  initialClients: clients,
                  initialSelected: selected,
                ),
      ),
    );
  } catch (e) {
    // Never leave the OS splash on screen forever: a database or client
    // failure here used to hang with nothing drawn and nothing logged on
    // the UI side. Surface it instead — the file/logcat log (if logging
    // itself came up) has the Rust-side detail.
    debugPrint('Startup failed: $e');
    runApp(ConduitApp(home: StartupErrorScreen(error: e.toString())));
  }
}

class ConduitApp extends StatelessWidget {
  final Widget home;

  const ConduitApp({super.key, required this.home});

  @override
  Widget build(BuildContext context) {
    return OverlaySupport.global(
      child: MaterialApp(
        title: "Eric's Conduit",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
          fontFamily: GoogleFonts.inter().fontFamily,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            titleTextStyle: mediumStyle,
          ),
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.deepPurple,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
          fontFamily: GoogleFonts.inter().fontFamily,
          appBarTheme: const AppBarTheme(
            centerTitle: true,
            titleTextStyle: mediumStyle,
          ),
        ),
        themeMode: ThemeMode.dark,
        home: home,
      ),
    );
  }
}
