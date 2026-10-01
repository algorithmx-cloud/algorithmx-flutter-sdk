# Flutter API and native parity

This reference lists the Flutter methods and callbacks alongside the current
Android `algorithmx.engage.core.AlgorithmX` and iOS `AlgorithmX.shared` APIs.
It is for developers who need more than the quick start. Import
`package:algorithmx_flutter/algorithmx_flutter.dart`; all calls below use
`AlgorithmX.instance` unless noted.

The native SDKs are the source of truth for notification payload keys, HTTP
formats, campaign rules, and UI. The Flutter plugin forwards these calls. Its
channel arguments are named maps so the Kotlin and Swift bridges read the same
keys.

## Common methods

| Dart method | Result | Android and iOS native operation | Notes |
| --- | --- | --- | --- |
| `initialize(apiBaseUrl: url)` | `Future<void>` | `initialize` | Required before normal use. The push entry points can initialize natively before Dart starts. Repeated initialization with the same URL is safe in the plugin; a different URL is an error. |
| `setDeviceFingerprint(value)` | `Future<void>` | `setDeviceFingerprint` | Overrides the automatically chosen Android ID or iOS vendor ID. |
| `getDeviceFingerprint()` | `Future<String?>` | `getDeviceFingerprint` | Returns the stored fingerprint, or null if not set. |
| `identifyUser(userId, attributes: map)` | `Future<void>` | `identifyUser` | Sets the effective fingerprint to `userId` (saved across restarts), sends an identify request with `previousFingerprintDevice`, and re-registers the push token. `attributes` is optional. |
| `resetIdentity()` | `Future<void>` | `resetIdentity` | Forgets the identified user (logout); the fingerprint goes back to the device id and the push token is re-registered. |
| `trackEvent(name, properties: map)` | `Future<void>` | `trackEvent` | Sends a generic event. `properties` is optional. |
| `trackCampaignInteraction(campaignId:, variationId:, interactionType:, payload:, sessionId:, endpoint:)` | `Future<void>` | `trackCampaignInteraction` | Optional payload, session ID, and endpoint override. Campaign/variation IDs are converted to integers by the native SDK for its HTTP body; nonnumeric IDs become `0`. |
| `updateNotificationStatus(notificationId, status, errorMessage:)` | `Future<void>` | `updateNotificationStatus` | Uses the status enum below. Native push handling already sends some statuses automatically. |
| `registerDeviceToken(token)` | `Future<void>` | `registerDeviceToken` | Send FCM token on Android or APNs token on iOS, including token refresh. |
| `showWebView(campaignId:, variationId:, url:, dynamicContent:, expiresAt:)` | `Future<void>` | `showWebView` | Shows the native campaign UI directly. `expiresAt` is Android-only; iOS ignores it. Use the normal push queue for ordinary campaigns. |
| `triggerWebView(campaignId:, webviewUrl:, dynamicContent:)` | `Future<void>` | `triggerWebView` | Manual immediate trigger for testing; bypasses normal queue rules. Fires `onWebViewTrigger`. |
| `setWebViewShowing(showing)` | `Future<void>` | `setWebViewShowing` | Advanced native UI coordination; normal display manages this flag. |
| `isWebViewCurrentlyShowing()` | `Future<bool>` | `isWebViewCurrentlyShowing` | Current native campaign UI state. |
| `openDeepLink(url)` | `Future<bool>` | `openDeepLink` / Dart handler | If a Dart handler exists, this direct Dart call awaits it. Native-originated `open_screen` invokes the Dart handler asynchronously. Neither native SDK automatically navigates to an app screen. |
| `getWebViewQueueSize()` | `Future<int>` | Android `getWebViewQueueSize`; iOS `getQueueSize` | Cross-platform count of queued campaigns. |
| `clearWebViewQueue()` | `Future<int>` | `clearWebViewQueue` | Returns removed queue entries; display history remains. |
| `clearAllWebViewData()` | `Future<bool>` | `clearAllWebViewData` | Clears queue and display history. Use deliberately. |
| `getDisplayStats(campaignId:, variationId:)` | `Future<String>` | `getDisplayStats` | Native diagnostic text for the current fingerprint and campaign variation. |

`getQueueSize()` is retained for native API completeness, but its meaning is
different: Android returns `0` (its event sender does not maintain a queue),
while iOS returns the WebView queue count. Use `getWebViewQueueSize()` for a
portable meaning.

### Notification status values

| Dart `NotificationEventStatus` | Wire value | Meaning |
| --- | ---: | --- |
| `sent` | 1 | Sent |
| `delivered` | 2 | Delivered |
| `opened` | 3 | Opened |
| `failedToSend` | 4 | Failed to send |
| `failedToDeliver` | 5 | Failed to deliver |

The Android and iOS native enums use these same values.

## Platform-specific entry points

Calling a method on the other platform results in a platform channel error.
Use your platform setup code to choose the entry point. The host's native push
service/delegate is preferred when the Flutter engine may be stopped.

| Dart method | Platform | Purpose |
| --- | --- | --- |
| `handleFcmMessage(data, notificationTitle:, notificationBody:)` | Android | Routes an FCM data message to silent campaign or visual notification handling. Use the native FCM service for background delivery. |
| `processNormalNotification(data, title:, body:)` | Android | Handles a known visual notification directly. Usually `handleFcmMessage` chooses this. |
| `processSilentNotification(data)` | Android | Handles a known silent campaign trigger directly. Usually `handleFcmMessage` chooses this. |
| `handleNotification(userInfo)` | iOS | Passes an APNs/UN notification payload to the native SDK. The AppDelegate should do this for background delivery. |
| `handleNotificationResponse(actionIdentifier:, userInfo:)` | iOS | Passes a tap or action button response to native handling. The AppDelegate should call this from `UNUserNotificationCenterDelegate`. |
| `handleNotificationClick(userInfo)` | iOS | Direct tap routing if the host already has only a payload; most apps should use `handleNotificationResponse`. |
| `setSmallIcon(resourceId)` | Android | Sets a native drawable resource ID for visual notifications. A Flutter asset path is not a drawable ID. |
| `getSmallIconResId()` | Android | Reads the current native notification icon ID. |
| `onAppBecameActive()` | Android | Manually asks the native campaign queue to process; the plugin normally forwards the app lifecycle. |
| `onAppWentBackground()` | Android | Manually resets a campaign session flag; the plugin normally forwards the app lifecycle. |
| `recordWebViewDisplaySuccess(campaignId:, variationId:, expiresAt:)` | Android | Advanced custom native WebView integration; the built-in campaign activity records this automatically. |
| `handleIntent()` / `handleNewIntent()` | Android | Re-processes the current Activity intent. The native lifecycle manager normally does this automatically. Dart cannot serialize an `Intent`. |
| `handleActionButtonClick(buttonId:, actionText:, title:, notificationData:)` | Android | Direct action button forwarding; ordinary native notification handling already does it. |
| `destroy()` | Android | Releases native lifecycle and queue resources. Call `initialize` again before further use. Not a logout API. |

The native Android API also has `setSmallIcon`/`getSmallIconResId` and a
`destroy` lifecycle method; iOS has no equivalent. The iOS native
`recordWebViewDisplaySuccess` method is internal to its campaign view
controller and is not a public API to bridge.

## Callbacks and streams

Each callback property has a corresponding broadcast stream. Use a callback
when your app needs to decide whether an action was handled. Use a stream for
observation. Cancel a `StreamSubscription` when its owner is disposed.

| Callback property | Stream | Data and behavior |
| --- | --- | --- |
| `onWebViewTrigger` | `webViewTriggers` | `WebViewTriggerEvent(campaignId, webviewUrl, dynamicContent)`. Native manual `triggerWebView` fires it. Silent push queue display is handled internally by the native SDK and does not fire this listener. |
| `onNotificationClick` | `notificationClicks` | Receives a map of the complete tap payload. Return `true` if Flutter handled it; `false` for native default action routing. |
| `onCustomAction` | `customActions` | Receives `action` and a map with `parsedActionData` for `action_type=custom_action`. Current native routers ignore this callback's bool after dispatch. |
| `onActionHandled` | `handledActions` | Protocol exists in both native SDKs, but their current routers do not invoke it. The Dart event is ready if the native code starts emitting it. |
| `onDeepLink` | `deepLinks` | Receives a URL string from an `open_screen` action or direct `openDeepLink`. The app handles navigation. |
| `onActionButtonClicked` | `actionButtonClicks` | `ActionButtonEvent(buttonId, actionText, title, notificationData)`. iOS false continues through normal tap routing; Android native currently ignores the returned bool. |
| `onCampaignInteraction` | `campaignInteractions` | `CampaignInteractionEvent(campaignId, variationId, interactionType, payload)` for native tracked interactions. |

Callback handler types accept `FutureOr`, so synchronous and `async` Dart
handlers both work. If a bool callback is absent or throws, the Dart bridge
returns `false`. The plugin performs default click routing only once after
that result. Streams are broadcast; late listeners do not receive past events.

### What default notification routing does

The native SDKs track a notification open and campaign click before asking the
notification click callback. If it returns `false`, the action router reads the
notification's `action_type` and JSON-string `actionData`:

| `action_type` | Default action |
| --- | --- |
| `open_web_page` | Open `actionData.url` in the system browser. |
| `open_webview` | Show a native campaign WebView using `actionData.url`. |
| `open_screen` | Offer `actionData.deepLink` to `onDeepLink`; your Flutter app decides navigation. |
| `custom_action` | Offer `actionData.action` to `onCustomAction`. |
| `standard`, absent, or unknown | No additional action. |

## Native notification payload and display behavior

Silent campaigns use `engage_action=algo_trigger_webview` with
`algo_campaign_id`, `engage_variation_id`, and `engage_webview_url`. Optional
`engage_dynamic_content` and `configs` are JSON strings. Android accepts a
missing variation ID as `0`; iOS currently requires a variation ID string.
The native queues persist campaign data in SQLite and apply their display
rules, including priority, max show count, interval, and expiry. The Flutter
plugin does not reimplement these rules in Dart.

Native campaign JavaScript actions include close, click, submit, and coupon
copy. They are tracked as campaign interactions, then forwarded to the Dart
campaign interaction callback when a Flutter engine is attached.

## Channel contract for maintainers

The single bidirectional channel is `algorithmx_flutter/methods`. Dart to
native calls use the method names in the tables above and a map of named
arguments. Void native operations return null; queries return `bool`, `int`,
`String`, or nullable `String`. Native to Dart calls use the seven callback
property names in the table and pass named maps. The channel supports a Dart
bool reply for notification click, custom action, deep link, and action button.

The native listener interfaces return bool synchronously. A platform channel
cannot synchronously wait for arbitrary async Dart code on the main thread.
The plugin therefore acknowledges the native callback, waits for Dart, and
continues only the default action branch if Dart did not handle a notification
click. It does not re-send open status or click tracking when it continues.
This is implemented separately in Kotlin and Swift and must stay aligned with
the native `NotificationActionRouter` when that router changes.
