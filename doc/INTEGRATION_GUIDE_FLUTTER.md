# Integrating AlgorithmX in a Flutter app

This guide assumes you have an existing Flutter app but have not worked with
Flutter plugins before. A **plugin** has Dart code plus Android Kotlin and iOS
Swift code. Your app calls the Dart API; Flutter registers the native bridge
when the app starts. Push notifications can also start an app process before
Dart starts, so the two platform setup sections are required for reliable push.

## 1. Prerequisites

- An AlgorithmX API base URL for your app.
- Flutter and its Android/iOS build tools installed (`flutter doctor` is a
  useful setup check).
- Android app with `minSdk` **24** or higher and Java 17. The SDK's Android
  module uses `compileSdk` 34 and Kotlin.
- iOS app with deployment target **15.0** or higher.
- FCM configured for Android push and APNs configured for iOS push. The host
  app owns push permission, credentials, and token refresh.

This plugin bundles the native SDK source. Do not also add the separate
`android-sdk` Gradle module or `AlgorithmXSDK` Swift package to the same Flutter app;
that would compile the same native classes twice.

## 2. Add the Flutter package

Open the app's `pubspec.yaml`. Under `dependencies`, add a path dependency to
this `flutter-sdk` directory. YAML indentation matters: use two spaces under
`dependencies` and four under `algorithmx_flutter`.

```yaml
dependencies:
  flutter:
    sdk: flutter
  algorithmx_flutter:
    path: /absolute/path/to/in-app-sdks/platforms/flutter/flutter-sdk  # or: algorithmx_flutter: ^1.0.0 from pub.dev
```

Then run these commands in the **Flutter app's** directory:

```bash
flutter pub get
flutter clean
flutter run
```

Use `flutter clean` when you first add native plugin code or after changing its
Android/iOS files. Normal Dart edits do not need it. The package is local in
this repository; it has not been published to pub.dev.

### Android project settings

Set `minSdk = 24` (or `minSdkVersion 24`, depending on your Flutter template)
in `android/app/build.gradle` or `android/app/build.gradle.kts`. Build with a
Java 17 toolchain. Add your Firebase `google-services.json` and Google
Services Gradle plugin according to your Firebase project's setup. The
[Firebase Android setup guide](https://firebase.google.com/docs/android/setup)
explains how to create the Firebase project and obtain that file.

The plugin declares the native campaign activity, notification receivers,
`INTERNET`, and `ACCESS_NETWORK_STATE` through its merged Android manifest.
Your app still needs its own FCM service and, for Android 13+, notification
permission handling.

### iOS project settings

Set the Runner deployment target to `15.0` or later in Xcode. Enable **Push
Notifications** and **Background Modes → Remote notifications** on the Runner
target. Add your APNs configuration to the app. Flutter builds the plugin with
Swift Package Manager on recent Flutter versions or CocoaPods on older setups;
both package descriptions are included. See Flutter's
[plugin package guide](https://docs.flutter.dev/packages-and-plugins/developing-packages)
and [Swift Package Manager guide](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)
if your existing iOS project has custom dependency settings.

## 3. Initialize and use the Dart API

Put initialization near the start of `lib/main.dart`. Register callbacks
**before** `initialize` so a startup notification can reach them. Use the same
base URL in Dart and in the native push entry points below.

```dart
import 'package:algorithmx_flutter/algorithmx_flutter.dart';
import 'package:flutter/material.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final sdk = AlgorithmX.instance;
  sdk.onNotificationClick = (data) async {
    // Example: let AlgorithmX perform its default action.
    return false;
  };
  sdk.onDeepLink = (url) async {
    // Send the URL through your app's own router, then return true.
    // Return false if your app did not handle it.
    return false;
  };

  await sdk.initialize(
    apiBaseUrl: 'https://your-algorithmx-endpoint.example.com',
  );
  runApp(const MyApp());
}
```

`AlgorithmX.instance` is the Dart singleton. `initialize` registers the native
bridge and initializes the native SDK in the current process. Call it before
tracking or querying queue state. If the native push service already initialized
the same process with the same URL, the bridge reuses that native instance.

Identify only after you know the app's user ID:

```dart
await AlgorithmX.instance.identifyUser(
  'user_12345',
  attributes: {'email': 'user@example.com', 'plan': 'premium'},
);
```

The SDK uses a platform device fingerprint before identification. Identifying
changes the fingerprint used by subsequent payloads, is saved across app restarts
(also when a push wakes the app), and moves the push token to the new identity at
once. On logout, call `await AlgorithmX.instance.resetIdentity();` to go back to the
device fingerprint.

Track application events and campaign interactions:

```dart
await AlgorithmX.instance.trackEvent(
  'purchase',
  properties: {
    'amount': 49.99,
    'currency': 'USD',
    'items': [
      {'sku': 'SKU123', 'quantity': 1},
    ],
  },
);

await AlgorithmX.instance.trackCampaignInteraction(
  campaignId: '123',
  variationId: '7',
  interactionType: 'click',
  payload: {'source': 'checkout'},
);
```

Maps crossing the Flutter channel must contain channel-compatible values:
strings, numbers, booleans, null, lists, and maps with string keys. Do not pass
a Dart class instance directly; convert it to a map first.

## 4. Android push setup

The AlgorithmX native SDK intentionally has no Firebase dependency. Your app
owns Firebase setup. Initialize in your `Application` subclass first, so a
notification tap that starts a killed app can be held until Flutter is ready.
Then forward FCM messages and tokens from a `FirebaseMessagingService`; this
works when Android starts the app in the background before the Flutter engine
exists.

The Kotlin service below imports `FirebaseMessagingService` and
`FirebaseMessaging`, so your **app** needs the Firebase Messaging Android
dependency. For the current Flutter Android template using Gradle Kotlin DSL,
add the Google Services plugin to `android/settings.gradle.kts`'s existing
`plugins` block, and add these lines to the existing blocks in
`android/app/build.gradle.kts`:

```kotlin
// android/settings.gradle.kts, inside plugins { ... }
id("com.google.gms.google-services") version "4.5.0" apply false

// android/app/build.gradle.kts, inside plugins { ... }
id("com.google.gms.google-services")

// android/app/build.gradle.kts, inside dependencies { ... }
implementation(platform("com.google.firebase:firebase-bom:34.19.0"))
implementation("com.google.firebase:firebase-messaging")
```

Put your Firebase project's `google-services.json` at
`android/app/google-services.json`. Firebase's
[FCM Android guide](https://firebase.google.com/docs/cloud-messaging/android/get-started)
has the corresponding Groovy syntax if your app uses `build.gradle` rather
than `build.gradle.kts`. Use the versions recommended by Firebase when you
update your app's Firebase dependencies.

If your app already has a `FirebaseMessagingService`, add the AlgorithmX calls
there. Only one code path should forward each message, or you can display and
track a notification twice.

```kotlin
// android/app/src/main/kotlin/<your/package>/MyApplication.kt
package your.app.package

import android.app.Application
import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.flutter.AlgorithmXFlutterPlugin
import com.google.firebase.messaging.FirebaseMessaging

internal const val ALGORITHM_X_URL =
    "https://your-algorithmx-endpoint.example.com"

class MyApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        AlgorithmXFlutterPlugin.initializeForBackground(this, ALGORITHM_X_URL)

        // onNewToken only runs when the token changes. Register the current
        // token on every fresh app install/start as well.
        FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
            AlgorithmX.registerDeviceToken(token)
        }
    }
}
```

Set `<application android:name=".MyApplication" ...>` in your Android
manifest. If your app already has an `Application` subclass, add only the
`initializeForBackground` call to its `onCreate` instead of creating another.

```kotlin
// android/app/src/main/kotlin/<your/package>/MyFirebaseMessagingService.kt
package your.app.package

import algorithmx.engage.core.AlgorithmX
import algorithmx.engage.flutter.AlgorithmXFlutterPlugin
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class MyFirebaseMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        super.onMessageReceived(message)

        // Dart might not have started yet. Initialize the native SDK first.
        AlgorithmXFlutterPlugin.initializeForBackground(application, ALGORITHM_X_URL)
        AlgorithmX.handleFcmMessage(
            applicationContext,
            message.data,
            message.notification?.title,
            message.notification?.body
        )
    }

    override fun onNewToken(token: String) {
        super.onNewToken(token)
        AlgorithmXFlutterPlugin.initializeForBackground(application, ALGORITHM_X_URL)
        AlgorithmX.registerDeviceToken(token)
    }
}
```

Declare the service in `android/app/src/main/AndroidManifest.xml`, inside the
same `<application android:name=".MyApplication">` element:

```xml
<service
    android:name=".MyFirebaseMessagingService"
    android:exported="false">
    <intent-filter>
        <action android:name="com.google.firebase.MESSAGING_EVENT" />
    </intent-filter>
</service>
```

Add `<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />`
outside `<application>` in that manifest, and request it at runtime on
Android 13+ at an appropriate point in your app. The SDK can receive data
messages without this permission, but Android may not show visual push
notifications until it is granted.

For an existing FCM token, call `AlgorithmX.instance.registerDeviceToken(token)`
from Dart after initialization, or call the native method from your service.
Repeat registration when Firebase rotates the token. Keep a single token source
for your app. If your app already uses another FCM service or a Flutter
messaging plugin, merge these forwarding calls into its existing delivery path
and make sure each message is forwarded once.

The SDK routes `engage_action=algo_trigger_webview` to its campaign queue and
`engage_action=algo_show_notification` to visible notification handling. It
also accepts a title and body from the FCM notification payload. Campaigns
queued while the app is inactive are considered when it becomes active; the
Flutter Android plugin forwards this lifecycle transition to the native SDK.
For a silent campaign that must reach `onMessageReceived` while the app is
backgrounded, send it as an FCM **data message** with the AlgorithmX keys in
`data`. Android's FCM SDK displays notification payloads itself in the
background and does not call this service for those messages; see Firebase's
[Android delivery table](https://firebase.google.com/docs/cloud-messaging/android/receive-messages).
For an SDK-controlled visible push, likewise send a data message with
`engage_action=algo_show_notification` and `title`/`body` in its data map so
the native SDK can display it and record its interaction events.

## 5. iOS push setup

Use your app's existing `AppDelegate.swift`; merge the calls below with code
already there. For a standard Flutter Runner target the class extends
`FlutterAppDelegate`. Replace the URL with **exactly** the one passed to Dart
`initialize`.

```swift
import Flutter
import UIKit
import UserNotifications
import algorithmx_flutter

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
    private let algorithmXURL =
        "https://your-algorithmx-endpoint.example.com"

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Initialize before a background APNs payload can be delivered.
        // Pass the App Group shared with your Notification Service Extension so it
        // can report delivered + impression (see the native iOS guide, §8.3).
        AlgorithmXFlutterPlugin.initializeForBackground(
            apiBaseUrl: algorithmXURL, appGroup: "group.com.yourcompany.yourapp"
        )
        UNUserNotificationCenter.current().delegate = self

        // This example asks at startup. Move the prompt behind your app's
        // own explanation screen if that is a better user experience.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, _ in
            if granted {
                DispatchQueue.main.async {
                    application.registerForRemoteNotifications()
                }
            }
        }
        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // Flutter's scene-based app template registers plugins when the engine
    // becomes available. Keep this generated registration method in place.
    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    }

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        AlgorithmX.shared.registerDeviceToken(token)
        super.application(application,
                          didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    // Optional: the plugin already forwards silent pushes (WebView campaigns) to the
    // SDK. If you override this for your own handling, forward to AlgorithmX as below
    // and do not also call super, or the push is handled twice.
    override func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        AlgorithmX.shared.handleNotification(userInfo: userInfo) {
            completionHandler(.newData)
        }
    }

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        AlgorithmX.shared.handleNotification(
            userInfo: notification.request.content.userInfo
        ) {
            completionHandler([.banner, .sound, .badge])
        }
    }

    override func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        AlgorithmX.shared.handleNotificationResponse(
            actionIdentifier: response.actionIdentifier,
            userInfo: response.notification.request.content.userInfo,
            completionHandler: completionHandler
        )
    }
}
```

The example requests notification permission and then registers with APNs. If
your app already has a push permission flow, keep that flow and remove the
example's duplicate request. If another plugin handles notification delegate
methods, merge these forwarding calls into that existing delegate and ensure
each Apple completion handler is called **once**.

### Rich images and action buttons on iOS

An iOS Notification Service Extension is a separate app target. Flutter cannot
create it automatically for a consuming app. In Xcode, choose **File → New →
Target → Notification Service Extension**. Add the package's vendored
`EngageNotificationService.swift` file to the **extension target**, then use a
`NotificationService.swift` like this:

```swift
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        guard let content = request.content.mutableCopy()
            as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        bestAttemptContent = content
        EngageNotificationService.processNotification(
            request: request,
            bestAttemptContent: content,
            contentHandler: contentHandler
        )
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler, let bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }
}
```

The file lives at
`flutter-sdk/ios/algorithmx_flutter/Sources/algorithmx_flutter/NativeSDK/Notifications/EngageNotificationService.swift`.
The extension uses its own copy because it is a separate process and should
only compile the notification extension helper. Rich notifications require
`mutable-content: 1` in the APNs payload.

## 6. Handle navigation and campaign callbacks

Callbacks are Dart properties on `AlgorithmX.instance`. Assign them before
`initialize`, and clear or replace them when the screen/router that owns them
is disposed. A navigation callback should use your app's router or a
`GlobalKey<NavigatorState>`; it should not assume a particular widget's
`BuildContext` will still be mounted when a push is tapped.

```dart
final sdk = AlgorithmX.instance;

sdk.onNotificationClick = (data) async {
  if (data['action_type'] == 'view_cart') {
    // Navigate in your app, then report that you handled this tap.
    navigatorKey.currentState?.pushNamed('/cart');
    return true;
  }
  // Run the SDK's normal action_type handling.
  return false;
};

sdk.onCustomAction = (action, data) async {
  if (action == 'view_product') {
    final parsed = data['parsedActionData'];
    // Read your product ID from parsed and navigate.
    return true;
  }
  return false;
};

sdk.onDeepLink = (url) async {
  // Parse and navigate with your app's router.
  return false;
};

sdk.onActionButtonClicked = (event) async {
  // event.buttonId, event.actionText, event.title,
  // event.notificationData are available.
  return false;
};

sdk.onCampaignInteraction = (event) async {
  // Observe native impression/click/submit/copy/close tracking.
};
```

The native SDK's click callback returns a `bool` synchronously, while Dart
callbacks can be asynchronous. The plugin claims the native click immediately,
waits for the Dart callback, and runs the native default action if Dart returns
`false` or throws. This keeps native open/click tracking from running twice.
If no Dart handler is assigned, the SDK default action is used. `onDeepLink`
has no automatic browser fallback in the native SDK; your app must navigate if
it wants to handle an `open_screen` action. On Android, the native SDK currently
ignores an action button handler's returned `bool`; on iOS `false` falls back
to regular notification click routing. See the [parity reference](API_AND_PARITY.md).

For a manual campaign preview:

```dart
await sdk.triggerWebView(
  campaignId: '123',
  webviewUrl: 'https://example.com/campaign',
  dynamicContent: {'name': 'Ada'},
);
```

The native SDK presents the WebView as an Android activity or iOS full-screen
view controller; you do not add a Flutter WebView widget.

## 7. Delivery and error behavior

`trackEvent`, `identifyUser`, token registration, status updates, and campaign
interactions hand work to the native network dispatcher. Their Dart `Future`
completes when the native method accepts the request, **before** the HTTP
response. The current native dispatchers do not persist failed requests for
retry. If you need server-confirmed delivery, that is a separate native SDK
feature to add; a successful Flutter `Future` alone does not provide it.

Platform channel errors (missing or invalid arguments, no native platform
implementation) surface as `PlatformException`/`MissingPluginException` in
Dart. Register callbacks before push handling so a cold-start tap is not lost.

## 8. Troubleshooting

| Symptom | Check |
| --- | --- |
| `MissingPluginException` | Run `flutter pub get`, clean, rebuild, and use Android/iOS rather than web/desktop. Hot reload does not install native code. |
| Android push arrives but no campaign | Ensure the FCM service initializes the native SDK before forwarding; verify `engage_action`, `algo_campaign_id`, and `engage_webview_url` in the data payload; bring the app to foreground to process queued views. |
| iOS silent push does nothing | Enable Background Modes → Remote notifications; verify `content-available: 1`; initialize in AppDelegate before forwarding; ensure the payload includes campaign, variation, and URL strings. |
| iOS image or buttons missing | Add the Notification Service Extension and its helper source; verify `mutable-content: 1`. |
| Visible push missing on Android 13+ | Request notification permission and confirm the app's FCM setup. |
| Tap navigates twice | Forward each push/tap once, and return `true` from a Dart callback after your app handles it. |
| Event `Future` succeeds but backend has no event | The native HTTP dispatcher is asynchronous; check the API URL, device networking, and native logs. |

## 9. Example and validation

The `example/` app demonstrates the Dart API. Before a push test, replace its
placeholder URL and configure FCM/APNs in the generated platform projects.
Test these flows on real devices: initial token, token refresh, silent campaign
while foreground/background, visual push tap, action button, deep link, and
rich iOS notification. Android emulators and iOS simulators can exercise many
UI methods but are not a full substitute for delivery through your push setup.
