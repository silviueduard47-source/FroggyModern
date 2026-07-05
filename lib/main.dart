import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:intl/intl.dart';

import 'services/system_status_service.dart';
import 'services/update_service.dart';
import 'services/window_service.dart';
import 'state/settings_controller.dart';
import 'state/weather_controller.dart';
import 'ui/froggy_view.dart';
import 'ui/settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const FroggyApp());
}

@pragma('vm:entry-point')
void dreamMain() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const FroggyApp(screensaver: true));
}

class FroggyApp extends StatefulWidget {
  const FroggyApp({super.key, this.screensaver = false});

  final bool screensaver;

  @override
  State<FroggyApp> createState() => _FroggyAppState();
}

class _FroggyAppState extends State<FroggyApp> {
  late final SettingsController _settings;
  late final WeatherController _weather;
  bool _isTv = false;

  @override
  void initState() {
    super.initState();
    _settings = SettingsController();
    _weather = WeatherController(
      settings: _settings,
      allowLocationPrompt: !widget.screensaver,
    );
    _settings.addListener(_applyWakelock);
    _detectTv();
    _boot();

    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  void _applyWakelock() {
    if (widget.screensaver) return;
    WindowService.setKeepAwake(_settings.settings.kioskMode);
  }

  Future<void> _detectTv() async {
    final tv = await SystemStatusService().isTelevision();
    if (mounted && tv) setState(() => _isTv = tv);
  }

  Future<void> _boot() async {
    await _settings.load();
    await _weather.init();
  }

  @override
  void dispose() {
    _settings.removeListener(_applyWakelock);
    if (!widget.screensaver) WindowService.setKeepAwake(false);
    _weather.dispose();
    _settings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Google's Weather Frog (Froggy)",
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'GoogleSansFlex'),
      ),
      builder: (context, child) {
        Widget result = Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
          },
          child: child!,
        );
        if (_isTv) {
          result = MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(navigationMode: NavigationMode.directional),
            child: result,
          );
        }
        return result;
      },
      home: widget.screensaver
          ? ScreensaverScreen(weather: _weather, settings: _settings)
          : HomeScreen(weather: _weather, settings: _settings),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.weather, required this.settings});

  final WeatherController weather;
  final SettingsController settings;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _kRotateHintDismissed = 'rotate_hint_dismissed';

  final _updates = UpdateService();
  bool _locationWarningDismissed = false;
  bool? _rotateHintDismissed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkForUpdate());
    if (kIsWeb) _loadRotateHint();
  }

  Future<void> _loadRotateHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_kRotateHintDismissed) ?? false;
    if (mounted) setState(() => _rotateHintDismissed = dismissed);
  }

  Future<void> _dismissRotateHint() async {
    setState(() => _rotateHintDismissed = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRotateHintDismissed, true);
  }

  bool _isMobilePortrait(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.height <= size.width) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void dispose() {
    _updates.dispose();
    super.dispose();
  }

  Future<void> _checkForUpdate() async {
    if (!widget.settings.settings.checkUpdatesOnStartup) return;
    final version = await WindowService.appVersion();
    if (version == null || version.isEmpty || !mounted) return;
    final info = await _updates.check(version);
    if (info == null || !info.updateAvailable || !mounted) return;
    if (!widget.settings.settings.checkUpdatesOnStartup) return;
    if (await _updates.skippedVersion() == info.latestVersion || !mounted) {
      return;
    }
    _showUpdateDialog(info);
  }

  void _showUpdateDialog(UpdateInfo info) {
    show
        
