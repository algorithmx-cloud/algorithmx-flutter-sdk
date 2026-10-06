# AlgorithmX Flutter SDK

> **Recommended naming: camelCase**
>
> We recommend `camelCase` for custom event names and payload keys, such as `addToCart` and `productId`. This is a recommendation only: the SDK does not enforce or normalize custom names or keys. Titles can use natural text in any language.
>
> SDK-defined fields, built-in events, and action types use the documented camelCase names. Legacy SDK push keys and built-in event/action names are still accepted on input; outgoing SDK tracking uses the canonical names. Your backend must accept `/api/v1/tracks/algoViewInteract`, with camelCase interaction fields and `payload` as a JSON string.

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

  await sdk.initialize(
    apiBaseUrl: 'https://api.example.com',
    partnerId: 'your-partner-id',
  );
  runApp(const MyApp());
}
```

AlgorithmX gives you the API base URL and your partner ID. The SDK sends the partner ID in the `x-partner-id` header of every SDK API request.

Identify customers after login and forward your business events:

```dart
await AlgorithmX.instance.identifyUser('customer_123', attributes: {'language': 'en'});
await AlgorithmX.instance.trackEvent('purchase', properties: {'total': 49.99, 'currency': 'USD'});
```

## SDK HTTP endpoints

API URLs are the initialized `apiBaseUrl` plus the paths below. Every SDK API request includes the `x-partner-id` header containing the initialized partner ID.

| Method | Endpoint | Purpose |
|---|---|---|
| `POST` | `/api/v1/identify` | Identify the customer and send optional attributes. |
| `POST` | `/api/v1/tracks/{eventName}` | Send a custom event with its original name and payload. |
| `POST` | `/api/v1/tracks/algoViewInteract` | Report campaign and push interactions. |
| `PUT` | `/api/v1/inAppPushEvents/device/status` | Update notification delivery or open status. |
| `POST` | `/api/v1/notificationTokens` | Register a push token for the current customer. |

`{eventName}` is the custom name supplied to `trackEvent`; the SDK keeps it unchanged. Campaign HTML and notification images are downloaded with `GET` from their supplied URLs, so those downloads have no fixed SDK path. Campaign HTML may also load its own resources. A caller-supplied campaign interaction `endpoint` overrides the default interaction path.

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
