import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'events.dart';

/// The Flutter entry point for AlgorithmX campaigns, push events, and tracking.
///
/// [instance] owns one [MethodChannel] for the current Flutter engine. Initialise
/// it once near app startup, before calling tracking or token methods. Android
/// and iOS keep their campaign display queues, local databases, networking, and
/// push notification routing in the existing native SDKs.
///
/// Native callbacks are delivered to the main Flutter isolate. If a callback
/// needs to decide whether the app handled an action, return `true` from the
/// corresponding handler. Return `false` to ask the native plugin to continue
/// its normal action routing. Native plugins provide this continuation after
/// the asynchronous Dart reply, so the result is meaningful on both platforms.
class AlgorithmX {
  AlgorithmX._(this._channel) {
    _channel.setMethodCallHandler(handleNativeCall);
  }

  /// The single instance used by normal applications.
  static final AlgorithmX instance = AlgorithmX._(
    const MethodChannel('algorithmx_flutter/methods'),
  );

  /// Builds an isolated SDK instance with a test channel.
  ///
  /// This constructor is only for tests. An application should always use
  /// [instance], because a MethodChannel has only one Dart-side call handler.
  @visibleForTesting
  AlgorithmX.forTesting(MethodChannel channel) : this._(channel);

  final MethodChannel _channel;

  final StreamController<WebViewTriggerEvent> _webViewTriggers =
      StreamController<WebViewTriggerEvent>.broadcast();
  final StreamController<AlgorithmXData> _notificationClicks =
      StreamController<AlgorithmXData>.broadcast();
  final StreamController<CustomActionEvent> _customActions =
      StreamController<CustomActionEvent>.broadcast();
  final StreamController<ActionHandledEvent> _handledActions =
      StreamController<ActionHandledEvent>.broadcast();
  final StreamController<String> _deepLinks =
      StreamController<String>.broadcast();
  final StreamController<ActionButtonEvent> _actionButtonClicks =
      StreamController<ActionButtonEvent>.broadcast();
  final StreamController<CampaignInteractionEvent> _campaignInteractions =
      StreamController<CampaignInteractionEvent>.broadcast();

  /// Observes WebView triggers without changing how the native SDK displays them.
  /// Cancel the [StreamSubscription] when its widget or service is disposed.
  Stream<WebViewTriggerEvent> get webViewTriggers => _webViewTriggers.stream;

  /// Observes notification taps. Use [onNotificationClick] if the Flutter app
  /// also needs to decide whether the SDK should run its default action.
  Stream<AlgorithmXData> get notificationClicks => _notificationClicks.stream;

  /// Observes parsed custom notification actions.
  Stream<CustomActionEvent> get customActions => _customActions.stream;

  /// Observes actions reported as handled by the native SDK.
  Stream<ActionHandledEvent> get handledActions => _handledActions.stream;

  /// Observes deep links passed to the SDK.
  Stream<String> get deepLinks => _deepLinks.stream;

  /// Observes notification action-button taps.
  Stream<ActionButtonEvent> get actionButtonClicks =>
      _actionButtonClicks.stream;

  /// Observes tracked campaign interactions, including impression and click.
  Stream<CampaignInteractionEvent> get campaignInteractions =>
      _campaignInteractions.stream;

  /// Called after a native campaign WebView trigger.
  ///
  /// This is for observation and optional app-side work. The native SDK handles
  /// campaign display and queue rules. If this is null, the trigger still works.
  FutureOr<void> Function(WebViewTriggerEvent event)? onWebViewTrigger;

  /// Called when a user taps a notification.
  ///
  /// Return `true` if Flutter handled the action, such as by navigating to a
  /// screen. Return `false` for the SDK's built-in action router to continue.
  /// The native SDK tracks the open before calling this handler.
  FutureOr<bool> Function(AlgorithmXData data)? onNotificationClick;

  /// Called for `action_type: "custom_action"` after native JSON parsing.
  ///
  /// [data] includes a `parsedActionData` map. Return `true` when handled.
  /// The current Android native router observes the callback result but has no
  /// additional fallback for an unhandled custom action.
  FutureOr<bool> Function(String? action, AlgorithmXData data)? onCustomAction;

  /// Called after native action handling when the platform emits that event.
  FutureOr<void> Function(ActionHandledEvent event)? onActionHandled;

  /// Called when an `open_screen` action passes a URL to the host app.
  ///
  /// Navigation belongs to your Flutter router. Return `true` if you handled
  /// the URL. Neither native SDK opens an arbitrary screen when this is absent.
  FutureOr<bool> Function(String url)? onDeepLink;

  /// Called for a notification action button.
  ///
  /// Return `true` when the app handled the button. On iOS, returning `false`
  /// lets the SDK route the regular notification click. Android's current
  /// native action-button method ignores its return value, so there is no
  /// equivalent automatic fallback on Android.
  FutureOr<bool> Function(ActionButtonEvent event)? onActionButtonClicked;

  /// Called after the native SDK tracks a campaign interaction.
  FutureOr<void> Function(CampaignInteractionEvent event)?
      onCampaignInteraction;

  /// Clears callback properties; existing stream subscriptions remain active.
  ///
  /// Assign handlers again when rebuilding app navigation after hot restart.
  void clearHandlers() {
    onWebViewTrigger = null;
    onNotificationClick = null;
    onCustomAction = null;
    onActionHandled = null;
    onDeepLink = null;
    onActionButtonClicked = null;
    onCampaignInteraction = null;
  }

  /// Initialises the native SDK with the AlgorithmX backend URL.
  ///
  /// Call once during startup before calling other methods. Native code stores
  /// this URL and begins watching the app lifecycle so queued campaigns can be
  /// displayed when the app becomes active.
  Future<void> initialize({required String apiBaseUrl}) =>
      _invokeVoid('initialize', {'apiBaseUrl': apiBaseUrl});

  /// Overrides the automatically generated device fingerprint.
  ///
  /// Android normally uses Android ID and iOS uses identifierForVendor. Use
  /// this only if your backend requires a stable, app-specific identifier.
  Future<void> setDeviceFingerprint(String fingerprint) =>
      _invokeVoid('setDeviceFingerprint', {'fingerprint': fingerprint});

  /// Returns the fingerprint currently used in native tracking requests.
  Future<String?> getDeviceFingerprint() => _channel.invokeMethod<String>(
        'getDeviceFingerprint',
        <String, Object?>{},
      );

  /// Associates subsequent SDK events with a signed-in user.
  ///
  /// Both native SDKs also set the effective fingerprint to [userId]. Optional
  /// [attributes] are sent with the identify request. Call this after login.
  Future<void> identifyUser(String userId, {AlgorithmXData? attributes}) =>
      _invokeVoid('identifyUser', {'userId': userId, 'attributes': attributes});

  /// Forgets the identified user (e.g. on logout); events go back to the device id.
  ///
  /// Both native SDKs save [identifyUser] across restarts until this is called.
  Future<void> resetIdentity() =>
      _invokeVoid('resetIdentity', <String, Object?>{});

  /// Tracks an arbitrary app event through the native SDK.
  ///
  /// [properties] can contain nested channel-safe maps and lists, such as
  /// `{'price': 19.95, 'items': [{'sku': 'A1'}]}`.
  Future<void> trackEvent(String name, {AlgorithmXData? properties}) =>
      _invokeVoid('trackEvent', {'name': name, 'properties': properties});

  /// Tracks a campaign interaction such as `impression`, `click`, or `close`.
  ///
  /// [endpoint] overrides the native default endpoint when your backend uses a
  /// custom route. The usual route is `/api/v1/tracks/algo_view_interact`.
  Future<void> trackCampaignInteraction({
    required String campaignId,
    required String variationId,
    required String interactionType,
    AlgorithmXData? payload,
    String? sessionId,
    String? endpoint,
  }) =>
      _invokeVoid('trackCampaignInteraction', {
        'campaignId': campaignId,
        'variationId': variationId,
        'interactionType': interactionType,
        'payload': payload,
        'sessionId': sessionId,
        'endpoint': endpoint,
      });

  /// Sends a push notification delivery or open state to the backend.
  ///
  /// Native push handling updates ordinary states automatically. This method
  /// is useful when the host app owns an additional notification entry point.
  Future<void> updateNotificationStatus(
    int notificationId,
    NotificationEventStatus status, {
    String? errorMessage,
  }) =>
      _invokeVoid('updateNotificationStatus', {
        'notificationId': notificationId,
        'status': status.code,
        'errorMessage': errorMessage,
      });

  /// Registers an FCM token on Android or an APNs token on iOS.
  ///
  /// The host app obtains the token through Firebase Messaging or APNs and
  /// forwards it here, including on token refresh. The native SDK adds the
  /// platform name and effective device fingerprint to the request.
  Future<void> registerDeviceToken(String token) =>
      _invokeVoid('registerDeviceToken', {'token': token});

  /// Android: forwards an FCM message to the native SDK.
  ///
  /// The SDK routes silent campaign triggers and visual notifications using
  /// the message's `engage_action` key. For delivery while the Flutter engine
  /// is stopped, wire your Android `FirebaseMessagingService` directly to the
  /// native SDK as shown in the integration guide.
  Future<void> handleFcmMessage(
    Map<String, String> data, {
    String? notificationTitle,
    String? notificationBody,
  }) =>
      _invokeVoid('handleFcmMessage', {
        'data': data,
        'notificationTitle': notificationTitle,
        'notificationBody': notificationBody,
      });

  /// Android: handles a visual push notification directly.
  ///
  /// Normally [handleFcmMessage] chooses this route for you. Use this only
  /// when a host-owned messaging service already knows the message is visual.
  Future<void> processNormalNotification(
    Map<String, String> data, {
    String? title,
    String? body,
  }) =>
      _invokeVoid('processNormalNotification', {
        'data': data,
        'title': title,
        'body': body,
      });

  /// Android: handles a silent in-app campaign message directly.
  ///
  /// Normally [handleFcmMessage] chooses this route for you.
  Future<void> processSilentNotification(Map<String, String> data) =>
      _invokeVoid('processSilentNotification', {'data': data});

  /// iOS: passes an APNs payload to the native SDK.
  ///
  /// AppDelegate should call the native `handleNotification` method directly
  /// for background delivery, since Dart may not be running at that moment.
  /// This method is for apps whose active Flutter layer owns that entry point.
  Future<void> handleNotification(AlgorithmXData userInfo) =>
      _invokeVoid('handleNotification', {'userInfo': userInfo});

  /// iOS: passes a notification tap or action-button response to native code.
  ///
  /// AppDelegate should forward native responses directly when Flutter is not
  /// active; the SDK can then route them after initialization.
  Future<void> handleNotificationResponse({
    required String actionIdentifier,
    required AlgorithmXData userInfo,
  }) =>
      _invokeVoid('handleNotificationResponse', {
        'actionIdentifier': actionIdentifier,
        'userInfo': userInfo,
      });

  /// iOS: routes a notification tap when the host already has its APNs data.
  /// Usually [handleNotificationResponse] is the appropriate entry point.
  Future<void> handleNotificationClick(AlgorithmXData userInfo) =>
      _invokeVoid('handleNotificationClick', {'userInfo': userInfo});

  /// Shows an in-app campaign in the native full-screen WebView.
  ///
  /// Normal campaigns display from the native queue automatically. Use this
  /// when your app deliberately wants to present a specific campaign URL.
  /// [expiresAt] is an optional Android expiration time in epoch milliseconds;
  /// iOS currently ignores it. Zero means no expiration.
  Future<void> showWebView({
    required String campaignId,
    required String variationId,
    required String url,
    AlgorithmXData? dynamicContent,
    int expiresAt = 0,
  }) =>
      _invokeVoid('showWebView', {
        'campaignId': campaignId,
        'variationId': variationId,
        'url': url,
        'dynamicContent': dynamicContent,
        'expiresAt': expiresAt,
      });

  /// Triggers a campaign immediately for testing.
  ///
  /// This bypasses the normal display queue and rules. Avoid it in production
  /// campaign flows; use a backend campaign trigger instead.
  Future<void> triggerWebView({
    required String campaignId,
    required String webviewUrl,
    AlgorithmXData? dynamicContent,
  }) =>
      _invokeVoid('triggerWebView', {
        'campaignId': campaignId,
        'webviewUrl': webviewUrl,
        'dynamicContent': dynamicContent,
      });

  /// Returns whether a native campaign WebView is currently visible.
  Future<bool> isWebViewCurrentlyShowing() =>
      _invokeBool('isWebViewCurrentlyShowing', <String, Object?>{});

  /// Overrides the native WebView-visible flag.
  ///
  /// Native presentation normally manages this flag. Use this only when
  /// integrating a custom native campaign presenter outside this plugin.
  Future<void> setWebViewShowing(bool showing) =>
      _invokeVoid('setWebViewShowing', {'showing': showing});

  /// Passes a deep link to the app's [onDeepLink] handler.
  ///
  /// When that handler is installed, Dart can return its actual `bool` result
  /// immediately without a duplicate trip through the native channel. If it
  /// is absent, the native SDK's handler decides whether [url] was handled.
  Future<bool> openDeepLink(String url) async {
    if (onDeepLink != null) {
      _deepLinks.add(url);
      return _runBool(() => onDeepLink?.call(url), 'onDeepLink');
    }
    return _invokeBool('openDeepLink', {'url': url});
  }

  /// Returns the native SDK's legacy queue count.
  ///
  /// Android's legacy event queue is no longer persisted and returns zero;
  /// iOS currently reports its WebView queue here. Prefer
  /// [getWebViewQueueSize] for the same meaning on both platforms.
  @Deprecated('Use getWebViewQueueSize for a cross-platform queue count.')
  Future<int> getQueueSize() => _invokeInt('getQueueSize', <String, Object?>{});

  /// Returns the number of campaigns waiting in the native WebView queue.
  Future<int> getWebViewQueueSize() =>
      _invokeInt('getWebViewQueueSize', <String, Object?>{});

  /// Removes queued campaigns without removing display history.
  /// Returns the number of removed queue entries.
  Future<int> clearWebViewQueue() =>
      _invokeInt('clearWebViewQueue', <String, Object?>{});

  /// Clears both the native campaign queue and display history.
  /// Use for testing or an explicit user data reset.
  Future<bool> clearAllWebViewData() =>
      _invokeBool('clearAllWebViewData', <String, Object?>{});

  /// Returns native display-rule statistics for a campaign variation.
  /// This is primarily a diagnostic string for support and testing.
  Future<String> getDisplayStats({
    required String campaignId,
    required String variationId,
  }) async {
    final value = await _channel.invokeMethod<String>('getDisplayStats', {
      'campaignId': campaignId,
      'variationId': variationId,
    });
    if (value == null) throw StateError('getDisplayStats returned null');
    return value;
  }

  /// Android: sets the drawable resource ID used for visual notifications.
  ///
  /// The ID must be an Android drawable resource (`R.drawable.name`), not a
  /// Flutter asset path. Configure it in native Android host code when possible.
  Future<void> setSmallIcon(int resourceId) =>
      _invokeVoid('setSmallIcon', {'resourceId': resourceId});

  /// Android: returns the configured notification small-icon resource ID.
  /// This is an Android drawable ID, not a Flutter asset path.
  Future<int> getSmallIconResId() =>
      _invokeInt('getSmallIconResId', <String, Object?>{});

  /// Android: asks the native SDK to process any queued WebViews now.
  /// Normally the SDK calls this automatically when the activity resumes.
  Future<void> onAppBecameActive() =>
      _invokeVoid('onAppBecameActive', <String, Object?>{});

  /// Android: resets the native per-session display flag.
  /// Normally the SDK calls this automatically when the app backgrounds.
  Future<void> onAppWentBackground() =>
      _invokeVoid('onAppWentBackground', <String, Object?>{});

  /// Android: records a successful custom WebView load.
  /// Native `CampaignActivity` calls this automatically for normal campaigns.
  Future<void> recordWebViewDisplaySuccess({
    required String campaignId,
    required String variationId,
    int expiresAt = 0,
  }) =>
      _invokeVoid('recordWebViewDisplaySuccess', {
        'campaignId': campaignId,
        'variationId': variationId,
        'expiresAt': expiresAt,
      });

  /// Android: re-routes the current activity's intent through the SDK.
  ///
  /// Flutter cannot serialize an Android `Intent`; the native plugin reads the
  /// current activity's intent. The SDK normally handles this automatically.
  Future<void> handleIntent() =>
      _invokeVoid('handleIntent', <String, Object?>{});

  /// Android: re-routes the current activity's most recent new intent.
  /// Normally activity lifecycle integration handles it automatically.
  Future<void> handleNewIntent() =>
      _invokeVoid('handleNewIntent', <String, Object?>{});

  /// Android: forwards a notification action-button click to the native SDK.
  /// Normal notification handling already performs this step automatically.
  Future<void> handleActionButtonClick({
    required String buttonId,
    required String actionText,
    required String title,
    required AlgorithmXData notificationData,
  }) =>
      _invokeVoid('handleActionButtonClick', {
        'buttonId': buttonId,
        'actionText': actionText,
        'title': title,
        'notificationData': notificationData,
      });

  /// Android: releases native lifecycle observers and queue resources.
  /// Re-initialise before calling other SDK methods after this.
  Future<void> destroy() => _invokeVoid('destroy', <String, Object?>{});

  Future<void> _invokeVoid(String method, AlgorithmXData arguments) async {
    await _channel.invokeMethod<void>(method, arguments);
  }

  Future<bool> _invokeBool(String method, AlgorithmXData arguments) async {
    final value = await _channel.invokeMethod<bool>(method, arguments);
    if (value == null) throw StateError('$method returned null');
    return value;
  }

  Future<int> _invokeInt(String method, AlgorithmXData arguments) async {
    final value = await _channel.invokeMethod<int>(method, arguments);
    if (value == null) throw StateError('$method returned null');
    return value;
  }

  /// Handles a call coming from Kotlin or Swift into Dart.
  ///
  /// Public for channel-level tests; application code should install the
  /// handler properties and never call this directly. Bool handlers resolve
  /// to `false` when absent or when app code throws, so native default routing
  /// can continue instead of leaving a notification action unanswered.
  @visibleForTesting
  Future<Object?> handleNativeCall(MethodCall call) async {
    final args = _asMap(call.arguments);
    switch (call.method) {
      case 'onWebViewTrigger':
        final event = WebViewTriggerEvent(
          campaignId: _asString(args['campaignId']),
          webviewUrl: _asString(args['webviewUrl']),
          dynamicContent: args['dynamicContent'] == null
              ? null
              : _asMap(args['dynamicContent']),
        );
        _webViewTriggers.add(event);
        await _runVoid(() => onWebViewTrigger?.call(event), call.method);
        return null;
      case 'onNotificationClick':
        final data = _asMap(args['data']);
        _notificationClicks.add(data);
        return _runBool(() => onNotificationClick?.call(data), call.method);
      case 'onCustomAction':
        final action = args['action'] as String?;
        final data = _asMap(args['data']);
        _customActions.add(CustomActionEvent(action: action, data: data));
        return _runBool(() => onCustomAction?.call(action, data), call.method);
      case 'onActionHandled':
        final event = ActionHandledEvent(
          action: _asString(args['action']),
          data: _asMap(args['data']),
        );
        _handledActions.add(event);
        await _runVoid(() => onActionHandled?.call(event), call.method);
        return null;
      case 'onDeepLink':
        final url = _asString(args['url']);
        _deepLinks.add(url);
        return _runBool(() => onDeepLink?.call(url), call.method);
      case 'onActionButtonClicked':
        final event = ActionButtonEvent(
          buttonId: _asString(args['buttonId']),
          actionText: _asString(args['actionText']),
          title: _asString(args['title']),
          notificationData: _asMap(args['notificationData']),
        );
        _actionButtonClicks.add(event);
        return _runBool(() => onActionButtonClicked?.call(event), call.method);
      case 'onCampaignInteraction':
        final event = CampaignInteractionEvent(
          campaignId: _asString(args['campaignId']),
          variationId: _asString(args['variationId']),
          interactionType: _asString(args['interactionType']),
          payload: _asMap(args['payload']),
        );
        _campaignInteractions.add(event);
        await _runVoid(() => onCampaignInteraction?.call(event), call.method);
        return null;
      default:
        throw MissingPluginException(
          'Unknown AlgorithmX callback: ${call.method}',
        );
    }
  }

  Future<bool> _runBool(
    FutureOr<bool>? Function() handler,
    String method,
  ) async {
    try {
      return await handler() ?? false;
    } catch (error, stack) {
      _reportCallbackError(method, error, stack);
      return false;
    }
  }

  Future<void> _runVoid(
    FutureOr<void>? Function() handler,
    String method,
  ) async {
    try {
      await handler();
    } catch (error, stack) {
      _reportCallbackError(method, error, stack);
    }
  }

  void _reportCallbackError(String method, Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'algorithmx_flutter',
        context: ErrorDescription('while handling native callback $method'),
      ),
    );
  }

  // StandardMethodCodec decodes native maps as Map<Object?, Object?>. Copying
  // their keys recursively lets callers use ordinary Map<String, Object?>
  // without unsafe casts in every notification or campaign callback.
  static AlgorithmXData _asMap(Object? raw) {
    if (raw == null) return <String, Object?>{};
    if (raw is! Map) throw FormatException('Expected a map, got $raw');
    return <String, Object?>{
      for (final entry in raw.entries)
        if (entry.key is String)
          (entry.key as String): _convertValue(entry.value),
    };
  }

  static Object? _convertValue(Object? raw) {
    if (raw is Map) return _asMap(raw);
    if (raw is List) return raw.map(_convertValue).toList(growable: false);
    return raw;
  }

  static String _asString(Object? raw) {
    if (raw is String) return raw;
    throw FormatException('Expected a string in AlgorithmX callback, got $raw');
  }
}
