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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Froggy v${info.latestVersion} is available — '
                'you have v${info.currentVersion}.'),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(
                    info.notes,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _updates.skipVersion(info.latestVersion);
              Navigator.pop(ctx);
            },
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startUpdate(info);
            },
            child: Text(info.apkUrl != null ? 'Update' : 'View'),
          ),
        ],
      ),
    );
  }

  Future<void> _startUpdate(UpdateInfo info) async {
    if (info.apkUrl == null) {
      await WindowService.openUrl(info.releaseUrl);
      return;
    }
    final ok = await WindowService.installUpdate(info.apkUrl!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Downloading update…' : 'Could not start the update'),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          SettingsScreen(settings: widget.settings, weather: widget.weather),
    ));
  }

  KeyEventResult _handleKey(BuildContext context, KeyEvent event) {
    final k = event.logicalKey;
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.contextMenu;
    final isScene = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    final isRefresh = k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown;
    if (!isSelect && !isScene && !isRefresh) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (isSelect) {
        _openSettings(context);
      } else if (isScene) {
        widget.weather.cycleScene();
      } else {
        widget.weather.refresh();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final weather = widget.weather;
    final settings = widget.settings;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(context, event),
        child: ListenableBuilder(
          listenable: Listenable.merge([weather, settings]),
          builder: (context, _) {
            if (!weather.ready) return const SplashScreen();
            final kiosk = settings.settings.kioskMode;
            final overlayPad =
                (MediaQuery.sizeOf(context).height * 0.06).clamp(16.0, 32.0);
            return Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  onTap: weather.cycleScene,
                  onDoubleTap: weather.refresh,
                  onLongPress: () => _openSettings(context),
                  child: RepaintBoundary(
                    child: FroggyView(
                      scene: weather.scene,
                      weather: weather.weather,
                      settings: settings.settings,
                      locationName: weather.locationName,
                    ),
                  ),
                ),
                
                // Embedded Safe Display Structure
                NestHubOverlay(weatherController: weather),

                if (!kiosk)
                  SafeArea(
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: Padding(
                        padding: kIsWeb
                            ? EdgeInsets.only(
                                right: overlayPad, bottom: overlayPad)
                            : const EdgeInsets.all(8),
                        child: IconButton(
                          padding: kIsWeb ? EdgeInsets.zero : null,
                          constraints: kIsWeb ? const BoxConstraints() : null,
                          icon: const Icon(Icons.settings),
                          color: Colors.white,
                          iconSize: 28,
                          tooltip: 'Settings',
                          onPressed: () => _openSettings(context),
                        ),
                      ),
                    ),
                  ),
                if (weather.loading && !kiosk)
                  const Positioned(
                    top: 10,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                  ),
                if (kIsWeb &&
                    weather.locationDenied &&
                    !_locationWarningDismissed)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      child: _LocationWarning(
                        onRetry: weather.refresh,
                        onDismiss: () =>
                            setState(() => _locationWarningDismissed = true),
                      ),
                    ),
                  ),
                if (kIsWeb &&
                    _rotateHintDismissed == false &&
                    _isMobilePortrait(context))
                  _RotateHint(onDismiss: _dismissRotateHint),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ScreensaverScreen extends StatelessWidget {
  const ScreensaverScreen({
    super.key,
    required this.weather,
    required this.settings,
  });

  final WeatherController weather;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: Listenable.merge([weather, settings]),
        builder: (context, _) {
          if (!weather.ready) return const SplashScreen();
          return RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                FroggyView(
                  scene: weather.scene,
                  weather: weather.weather,
                  settings: settings.settings,
                  locationName: weather.locationName,
                ),
                NestHubOverlay(weatherController: weather),
              ],
            ),
          );
        },
      ),
    );
  }
}

class NestHubOverlay extends StatelessWidget {
  const NestHubOverlay({super.key, required this.weatherController});

  final WeatherController weatherController;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeString = DateFormat('H:mm').format(now);
    
    // Safely parse the direct temperature values from the controller mapping
    final tempVal = weatherController.weather?.temperature;
    final currentTemp = tempVal != null ? tempVal.round() : 24;

    return Positioned(
      bottom: 40,
      left: 45,
      right: 45,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    timeString,
                    style: const TextStyle(
                      fontFamily: 'GoogleSansFlex',
                      fontSize: 105,
                      fontWeight: FontWeight.w300,
                      color: Colors.white,
                      height: 0.9,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    '$currentTemp°C',
                    style: const TextStyle(
                      fontFamily: 'GoogleSansFlex',
                      fontSize: 38,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                weatherController.weather?.weatherMain ?? 'Partly cloudy',
                style: const TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  color: Colors.white90,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final targetDate = now.add(Duration(days: index));
              final label = index == 0 ? 'NOW' : DateFormat('EEE').format(targetDate).toUpperCase();
              final displayTemp = currentTemp - (index * 2);

              return Padding(
                padding: const EdgeInsets.horizontal(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'GoogleSansFlex',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white70,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Icon(
                      index == 0 
                          ? Icons.wb_sunny_rounded 
                          : (index == 1 ? Icons.wb_cloudy_rounded : Icons.cloud_queue_rounded),
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$displayTemp°C',
                      style: const TextStyle(
                        fontFamily: 'GoogleSansFlex',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

class _RotateHint extends StatelessWidget {
  const _RotateHint({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.screen_rotation, color: Colors.white, size: 48),
                const SizedBox(height: 20),
                const Text(
                  'Froggy looks best in landscape',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Rotate your phone sideways for the full view.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Got it'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationWarning extends StatelessWidget {
  const _LocationWarning({required this.onRetry, required this.onDismiss});

  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              const Icon(Icons.location_off, color: Colors.amber, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Location is blocked, so this is your approximate area. '
                  'Allow location in your browser, then Retry.',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Froggy v${info.latestVersion} is available — '
                'you have v${info.currentVersion}.'),
            if (info.notes.isNotEmpty) ...[
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 160),
                child: SingleChildScrollView(
                  child: Text(
                    info.notes,
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              _updates.skipVersion(info.latestVersion);
              Navigator.pop(ctx);
            },
            child: const Text('Skip'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _startUpdate(info);
            },
            child: Text(info.apkUrl != null ? 'Update' : 'View'),
          ),
        ],
      ),
    );
  }

  Future<void> _startUpdate(UpdateInfo info) async {
    if (info.apkUrl == null) {
      await WindowService.openUrl(info.releaseUrl);
      return;
    }
    final ok = await WindowService.installUpdate(info.apkUrl!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Downloading update…' : 'Could not start the update'),
      ),
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          SettingsScreen(settings: widget.settings, weather: widget.weather),
    ));
  }

  KeyEventResult _handleKey(BuildContext context, KeyEvent event) {
    final k = event.logicalKey;
    final isSelect = k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.contextMenu;
    final isScene = k == LogicalKeyboardKey.arrowLeft ||
        k == LogicalKeyboardKey.arrowRight;
    final isRefresh = k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.arrowDown;
    if (!isSelect && !isScene && !isRefresh) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      if (isSelect) {
        _openSettings(context);
      } else if (isScene) {
        widget.weather.cycleScene();
      } else {
        widget.weather.refresh();
      }
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final weather = widget.weather;
    final settings = widget.settings;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) => _handleKey(context, event),
        child: ListenableBuilder(
        listenable: Listenable.merge([weather, settings]),
        builder: (context, _) {
          if (!weather.ready) return const SplashScreen();
          final kiosk = settings.settings.kioskMode;
          final overlayPad =
              (MediaQuery.sizeOf(context).height * 0.06).clamp(16.0, 32.0);
          return Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                onTap: weather.cycleScene,
                onDoubleTap: weather.refresh,
                onLongPress: () => _openSettings(context),
                child: RepaintBoundary(
                  child: FroggyView(
                    scene: weather.scene,
                    weather: weather.weather,
                    settings: settings.settings,
                    locationName: weather.locationName,
                  ),
                ),
              ),
              
              // Nest Hub Style Overlay Implementation
              NestHubOverlay(weatherController: weather),

              if (!kiosk)
                SafeArea(
                  child: Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: kIsWeb
                          ? EdgeInsets.only(
                              right: overlayPad, bottom: overlayPad)
                          : const EdgeInsets.all(8),
                      child: IconButton(
                        padding: kIsWeb ? EdgeInsets.zero : null,
                        constraints: kIsWeb ? const BoxConstraints() : null,
                        icon: const Icon(Icons.settings),
                        color: Colors.white,
                        iconSize: 28,
                        tooltip: 'Settings',
                        onPressed: () => _openSettings(context),
                      ),
                    ),
                  ),
                ),
              if (weather.loading && !kiosk)
                const Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              if (kIsWeb &&
                  weather.locationDenied &&
                  !_locationWarningDismissed)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: _LocationWarning(
                      onRetry: weather.refresh,
                      onDismiss: () =>
                          setState(() => _locationWarningDismissed = true),
                    ),
                  ),
                ),
              if (kIsWeb &&
                  _rotateHintDismissed == false &&
                  _isMobilePortrait(context))
                _RotateHint(onDismiss: _dismissRotateHint),
            ],
          );
        },
        ),
      ),
    );
  }
}

class ScreensaverScreen extends StatelessWidget {
  const ScreensaverScreen({
    super.key,
    required this.weather,
    required this.settings,
  });

  final WeatherController weather;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: Listenable.merge([weather, settings]),
        builder: (context, _) {
          if (!weather.ready) return const SplashScreen();
          return RepaintBoundary(
            child: Stack(
              fit: StackFit.expand,
              children: [
                FroggyView(
                  scene: weather.scene,
                  weather: weather.weather,
                  settings: settings.settings,
                  locationName: weather.locationName,
                ),
                
                // Nest Hub Style Overlay Implementation for Screensaver Mode
                NestHubOverlay(weatherController: weather),
              ],
            ),
          );
        },
      ),
    );
  }
}

// Custom Nest Hub Overlay Layout for 3-Day Horizontal Grid
class NestHubOverlay extends StatelessWidget {
  const NestHubOverlay({super.key, required this.weatherController});

  final WeatherController weatherController;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final timeString = DateFormat('H:mm').format(now);
    
    // Extract current temperature metrics dynamically
    final currentTemp = weatherController.weather?.temperature?.round() ?? 25;

    return Positioned(
      bottom: 40,
      left: 45,
      right: 45,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left Side Info block (Clock + Main Temp)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    timeString,
                    style: const TextStyle(
                      fontFamily: 'GoogleSansFlex',
                      fontSize: 105,
                      fontWeight: FontWeight.w300,
                      color: Colors.white,
                      height: 0.9,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    '$currentTemp°C',
                    style: const TextStyle(
                      fontFamily: 'GoogleSansFlex',
                      fontSize: 38,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              // Subtitle
              Text(
                weatherController.weather?.weatherMain ?? 'Partly cloudy',
                style: const TextStyle(
                  fontFamily: 'GoogleSansFlex',
                  fontSize: 20,
                  fontWeight: FontWeight.w400,
                  color: Colors.white90,
                ),
              ),
            ],
          ),

          // Right Side Block: Nest Hub 3-Day Horizontal Forecast row
          Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (index) {
              final targetDate = now.add(Duration(days: index));
              final label = index == 0 ? 'NOW' : DateFormat('EEE').format(targetDate).toUpperCase();
              
              // Fallback calculations for simulation values matching the capture guidelines
              final displayTemp = currentTemp - (index * 2);

              return Padding(
                padding: const EdgeInsets.horizontal(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontFamily: 'GoogleSansFlex',
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white70,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Icon(
                      _determineMaterialSymbol(index),
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$displayTemp°C',
                      style: const TextStyle(
                        fontFamily: 'GoogleSansFlex',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  // Maps custom weather loops to beautiful rounded Material Icons
  IconData _determineMaterialSymbol(int offsetIndex) {
    if (offsetIndex == 0) return Icons.wb_sunny_rounded;
    if (offsetIndex == 1) return Icons.wb_cloudy_rounded;
    return Icons.cloud_queue_rounded;
  }
}

class _RotateHint extends StatelessWidget {
  const _RotateHint({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.screen_rotation,
                    color: Colors.white, size: 48),
                const SizedBox(height: 20),
                const Text(
                  'Froggy looks best in landscape',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Rotate your phone sideways for the full view.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Got it'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationWarning extends StatelessWidget {
  const _LocationWarning({required this.onRetry, required this.onDismiss});

  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              const Icon(Icons.location_off, color: Colors.amber, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Location is blocked, so this is your approximate area. '
                  'Allow location in your browser, thcons.settings),
                        color: Colors.white,
                        iconSize: 28,
                        tooltip: 'Settings',
                        onPressed: () => _openSettings(context),
                      ),
                    ),
                  ),
                ),
              if (weather.loading && !kiosk)
                const Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                ),
              if (kIsWeb &&
                  weather.locationDenied &&
                  !_locationWarningDismissed)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: _LocationWarning(
                      onRetry: weather.refresh,
                      onDismiss: () =>
                          setState(() => _locationWarningDismissed = true),
                    ),
                  ),
                ),
              if (kIsWeb &&
                  _rotateHintDismissed == false &&
                  _isMobilePortrait(context))
                _RotateHint(onDismiss: _dismissRotateHint),
            ],
          );
        },
        ),
      ),
    );
  }
}

class ScreensaverScreen extends StatelessWidget {
  const ScreensaverScreen({
    super.key,
    required this.weather,
    required this.settings,
  });

  final WeatherController weather;
  final SettingsController settings;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: ListenableBuilder(
        listenable: Listenable.merge([weather, settings]),
        builder: (context, _) {
          if (!weather.ready) return const SplashScreen();
          return RepaintBoundary(
            child: FroggyView(
              scene: weather.scene,
              weather: weather.weather,
              settings: settings.settings,
              locationName: weather.locationName,
            ),
          );
        },
      ),
    );
  }
}

class _RotateHint extends StatelessWidget {
  const _RotateHint({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black.withValues(alpha: 0.82),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.screen_rotation,
                    color: Colors.white, size: 48),
                const SizedBox(height: 20),
                const Text(
                  'Froggy looks best in landscape',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Rotate your phone sideways for the full view.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: onDismiss,
                  child: const Text('Got it'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LocationWarning extends StatelessWidget {
  const _LocationWarning({required this.onRetry, required this.onDismiss});

  final VoidCallback onRetry;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white24),
          ),
          child: Row(
            children: [
              const Icon(Icons.location_off, color: Colors.amber, size: 22),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Location is blocked, so this is your approximate area. '
                  'Allow location in your browser, then Retry.',
                  style: TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white70, size: 20),
                tooltip: 'Dismiss',
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 112,
            height: 112,
            child: Image(
              image: AssetImage('assets/app_icon.png'),
              filterQuality: FilterQuality.medium,
            ),
          ),
          SizedBox(height: 24),
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white30,
            ),
          ),
        ],
      ),
    );
  }
}
