# AlgorithmX Flutter example

This small app shows initialization, event tracking, token registration,
campaign testing, and all native callbacks. The screen intentionally has no
Firebase dependency so it can be used with either a real Firebase project or
manual tokens during integration.

The `android/` and `ios/` runner directories are included. Run the app with:

```sh
cd example
flutter pub get
flutter run
```

Follow the parent package's integration guide for Android FCM and iOS APNs
setup. The generated Flutter runners do not add Firebase,
notification permissions, or the iOS Notification Service Extension.

The URL, user ID, and token text fields are local demo inputs. They are not
stored or sent anywhere except through SDK methods you tap on this screen.
