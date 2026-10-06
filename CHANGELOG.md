# Changelog

## 1.0.2

- Bundled native sources match AlgorithmX Android and iOS SDK 1.0.2.

- Fixed notification endpoints now use `/api/v1/inAppPushEvents/device/status` and `/api/v1/notificationTokens` instead of `/api/v1/in-app-push-events/device/status` and `/api/v1/notification-tokens`. The backend must accept the new routes before this SDK release; the local test backend retains the previous routes as aliases. The `x-partner-id` header stays unchanged.
- SDK-defined tracking fields, push fields, built-in events, and action names now use camelCase. Campaign interactions use `/api/v1/tracks/algoViewInteract` and camelCase fields; `payload` remains a JSON string. The backend must support this contract before release.
- Previous fixed push keys/action names and campaign bridge events remain accepted on input. Custom event names, payload keys, nested data, action text, and titles retain their supplied spelling; camelCase is recommended in the guides.
- WebView impression personalization is emitted in a `dynamicContent` object containing the original custom keys and their text values.

## 1.0.1

- **Breaking:** `initialize` takes the partner ID that AlgorithmX gives you: `initialize(apiBaseUrl:, partnerId:)`. The native helpers changed the same way: `AlgorithmXFlutterPlugin.initializeForBackground(application, apiBaseUrl, partnerId)` (Android) and `initializeForBackground(apiBaseUrl:partnerId:appGroup:)` (iOS). A different partner ID than the first initialization is an error, like a different URL.
- The SDK sends the partner ID in the `x-partner-id` header of every request. Bundled native SDKs match AlgorithmX Android SDK 1.0.1 and iOS SDK 1.0.1.

## 1.0.0

- First public release on pub.dev.
- The bundled iOS SDK is now named `AlgorithmXSDK` (previously `EngageSDK`).
- Bundled native SDKs match AlgorithmX Android SDK 1.0.0 and iOS SDK 1.0.0.

## 0.1.0

- Added the AlgorithmX Flutter API for Android and iOS, including tracking,
  identity, push entry points, campaign WebViews, display queue controls, and
  notification callbacks.
- Bundled the current native Android and iOS SDK sources so Flutter apps can
  use the plugin without separate native SDK package references.
- Added cold-start push initialization helpers, deferred Dart callback
  decisions for native notification actions, and an example Flutter app.
- Added the integration, API parity, and architecture guides.
