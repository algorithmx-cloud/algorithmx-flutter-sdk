import 'dart:async';

import 'package:algorithmx_flutter/algorithmx_flutter.dart';
import 'package:flutter/material.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ExampleApp());
}

/// A compact test app for the public Dart API.
///
/// A real app normally initialises AlgorithmX in its startup/bootstrap service
/// and installs callbacks near its router. Keeping everything on one screen
/// makes the call order and callback payloads easier to inspect while learning.
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'AlgorithmX Flutter example',
        theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
        home: const ExampleScreen(),
      );
}

class ExampleScreen extends StatefulWidget {
  const ExampleScreen({super.key});

  @override
  State<ExampleScreen> createState() => _ExampleScreenState();
}

class _ExampleScreenState extends State<ExampleScreen> {
  final _apiUrl = TextEditingController(
    text: 'https://your-algorithmx-endpoint.example.com',
  );
  final _partnerId = TextEditingController(text: 'your-partner-id');
  final _userId = TextEditingController(text: 'flutter-demo-user');
  final _token = TextEditingController();
  final _logLines = <String>[];
  final _sdk = AlgorithmX.instance;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();

    // Native callbacks can arrive after any SDK call, so install handlers
    // before initialize. The bool result determines whether native default
    // notification routing should continue.
    _sdk.onNotificationClick = (data) async {
      _log('Notification tapped: $data');
      return false; // Let the SDK open URLs/WebViews as configured.
    };
    _sdk.onCustomAction = (action, data) async {
      _log('Custom action $action: $data');
      return false;
    };
    _sdk.onDeepLink = (url) async {
      _log('Deep link: $url');
      return false; // Replace with your Flutter router, then return true.
    };
    _sdk.onActionButtonClicked = (event) async {
      _log('Button ${event.buttonId}: ${event.notificationData}');
      // iOS falls back to the regular click when false. Android currently
      // has no additional action-button fallback in the native SDK.
      return false;
    };
    _sdk.onActionHandled = (event) => _log('Handled ${event.action}');
    _sdk.onWebViewTrigger =
        (event) => _log('WebView ${event.campaignId}: ${event.webviewUrl}');
    _sdk.onCampaignInteraction = (event) => _log(
          'Campaign ${event.campaignId}/${event.variationId}: '
          '${event.interactionType}',
        );
  }

  @override
  void dispose() {
    // A singleton outlives this screen. Clear closures that capture this
    // State, so later native callbacks cannot update a disposed widget.
    _sdk.clearHandlers();
    _apiUrl.dispose();
    _partnerId.dispose();
    _userId.dispose();
    _token.dispose();
    super.dispose();
  }

  void _log(String message) {
    if (!mounted) return;
    setState(() => _logLines.insert(0, message));
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    try {
      await action();
      _log('$label completed');
    } catch (error) {
      _log('$label failed: $error');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('AlgorithmX Flutter example')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Call initialize first. Then identify the user, register the '
              'push token, and track events. To receive push, configure native '
              'entry points in the Android/iOS runner as shown in the '
              'integration guide.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _apiUrl,
              decoration:
                  const InputDecoration(labelText: 'AlgorithmX API URL'),
            ),
            TextField(
              controller: _partnerId,
              decoration: const InputDecoration(labelText: 'Partner ID'),
            ),
            ElevatedButton(
              onPressed: () => _run('Initialize', () async {
                await _sdk.initialize(
                  apiBaseUrl: _apiUrl.text.trim(),
                  partnerId: _partnerId.text.trim(),
                );
                if (mounted) setState(() => _initialized = true);
              }),
              child: const Text('1. Initialize'),
            ),
            TextField(
              controller: _userId,
              decoration: const InputDecoration(labelText: 'User ID'),
            ),
            ElevatedButton(
              onPressed: !_initialized
                  ? null
                  : () => _run(
                        'Identify',
                        () => _sdk.identifyUser(
                          _userId.text.trim(),
                          attributes: {'source': 'flutter-example'},
                        ),
                      ),
              child: const Text('2. Identify user'),
            ),
            TextField(
              controller: _token,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'FCM or APNs token'),
            ),
            ElevatedButton(
              onPressed: !_initialized || _token.text.trim().isEmpty
                  ? null
                  : () => _run(
                        'Register token',
                        () => _sdk.registerDeviceToken(_token.text.trim()),
                      ),
              child: const Text('3. Register push token'),
            ),
            ElevatedButton(
              onPressed: !_initialized
                  ? null
                  : () => _run(
                        'Track event',
                        () => _sdk.trackEvent(
                          'flutterExampleOpened',
                          properties: {'screen': 'example'},
                        ),
                      ),
              child: const Text('Track test event'),
            ),
            ElevatedButton(
              onPressed: !_initialized
                  ? null
                  : () => _run(
                        'Show test WebView',
                        () => _sdk.triggerWebView(
                          campaignId: 'flutter-demo',
                          webviewUrl: 'https://example.com',
                          dynamicContent: {'source': 'flutter-example'},
                        ),
                      ),
              child: const Text('Show test campaign WebView'),
            ),
            const SizedBox(height: 16),
            Text(
              'Callbacks and results',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            for (final line in _logLines) Text('• $line'),
          ],
        ),
      );
}
