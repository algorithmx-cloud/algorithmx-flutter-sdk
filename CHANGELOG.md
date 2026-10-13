# Changelog

## 1.1.0 — October 13, 2026

- Production API-based in-app delivery requires the backend work tracked in [AlgorithmX issue #207](https://github.com/algorithmx-cloud/AlgorithmX/issues/207). SDK flows were verified on physical Android and iOS devices against the local test backend.

- API-based in-app views now work across Android, iOS, React Native/Expo and Flutter. Fetch automatically on startup/foreground and identity changes, with device/app language, anonymous/device UUID headers, and ExternalId as customerId after identify.
- Inline HTML/CSS/JS, translated text/placeholders/RTL, fractional stable allocation, local account-based history, priority/frequency/expiry and enter-time delay are shared across native implementations. Legacy silent in-app triggers are ignored; visible push and manual previews remain separate.
- API-view interactions use the backend's Event/Log contract with string UUIDs and the identity captured at display time. Ordered GETs, bounded 409/network retries and connectivity recovery minimise host integration work.

- Generate and persist anonymous and installation device UUIDs inside the SDK. Bootstrap the profile through `/api/v1/Identity/Bootstrap`.
- Identify through `/api/v1/Identity` using `anonymousId` and trusted identifiers: ExternalId, Email, Phone and UserName. Login preserves the anonymous UUID; logout/account switching creates a new one and clears waiting campaigns.
- Map supported customer traits to `/api/v1/Customer/Ingest` with profile headers. Add `setUserProfile` and `getAnonymousId`; reject unsupported profile fields. Customer ingestion replaces the complete set of supported fields.
- Send events with the anonymous UUID after login; keep account IDs separate. Serialize SDK HTTP requests in call order. The backend processes accepted requests asynchronously on separate queues.
- Legacy `setDeviceFingerprint` now accepts only anonymous UUIDs. Native dependency requirements are 1.1.0.

## 1.0.3

- General `trackEvent` requests now use `POST /api/v1/Event/Log` with an array of `{ eventType, data, timestamp }` events and ISO 8601 UTC timestamps. Empty properties are sent as `{}`.
- Event requests send the current SDK fingerprint in `X-Anonymous-Id`, alongside `x-partner-id`. Event names and custom data retain their supplied spelling.
- Campaign/push interaction, identity, notification-status, and push-token endpoints retain their existing contracts.
- Bundled native sources match Android/iOS SDK 1.0.3.

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
