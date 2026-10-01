# AlgorithmX Flutter SDK

Connect your Flutter app to [AlgorithmX](https://algorithmx.cloud), the campaign management and customer data platform. The plugin sends customer identity and events, handles AlgorithmX push notifications, routes campaign actions to your navigation, and shows in-app campaigns on Android and iOS.

The plugin contains the native AlgorithmX Android and iOS SDKs, so you do not add them separately.

- Android: minSdk 24 or later
- iOS: 15.0 or later
- Flutter 3.19 or later

## Installation

```bash
flutter pub add algorithmx_flutter
```

## Quick start

Start the SDK in your native entry points (Android `Application`, iOS `AppDelegate`) so pushes that start the app before Dart runs are handled. Then set your handlers and bind Dart to the SDK with the same URL:

```dart
import 'package:algorithmx_flutter/algorithmx_flutter.dart';
import 'package:flutter/widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final sdk = AlgorithmX.instance;

  sdk.onDeepLink = (url) {
    // Open the URL with your router; return true when handled.
    return false;
  };

  await sdk.initialize(apiBaseUrl: 'https://api.example.com');
  runApp(const MyApp());
}
```

Identify customers after login and forward your business events:

```dart
await AlgorithmX.instance.identifyUser('customer_123', attributes: {'language': 'en'});
await AlgorithmX.instance.trackEvent('purchase', properties: {'total': 49.99, 'currency': 'USD'});
```

The integration guide covers the native setup, push notifications on both platforms, navigation handlers, and testing.

**[Flutter integration guide →](https://algorithmx.cloud/en/docs/integrations/flutter)**

## Development checks

From the repository root:

```bash
flutter pub get
flutter analyze
flutter test
python3 tool/sync_native_sdks.py --check
```

`tool/sync_native_sdks.py` keeps the bundled native code identical to the native SDK repositories; it only works inside the AlgorithmX SDK monorepo.

## License

MIT. See [LICENSE](LICENSE).
