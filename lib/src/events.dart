/// Values supported in a platform-channel map: null, booleans, numbers, strings,
/// lists, and maps made from those values. Avoid custom Dart objects in payloads.
typedef AlgorithmXData = Map<String, Object?>;

/// Notification delivery state understood by both native SDKs.
///
/// The integer codes are part of the AlgorithmX backend protocol. They must
/// remain aligned with Android's and iOS's `NotificationEventStatus` values.
enum NotificationEventStatus {
  sent(1),
  delivered(2),
  opened(3),
  failedToSend(4),
  failedToDeliver(5);

  const NotificationEventStatus(this.code);

  /// Numeric status included in the native request to the backend.
  final int code;
}

/// A native campaign WebView was triggered.
///
/// Native SDKs decide when a queued campaign may be shown. This event lets the
/// Flutter app observe that decision; normal campaign display remains native.
class WebViewTriggerEvent {
  const WebViewTriggerEvent({
    required this.campaignId,
    required this.webviewUrl,
    this.dynamicContent,
  });

  final String campaignId;
  final String webviewUrl;
  final AlgorithmXData? dynamicContent;
}

/// A notification action button was tapped.
class ActionButtonEvent {
  const ActionButtonEvent({
    required this.buttonId,
    required this.actionText,
    required this.title,
    required this.notificationData,
  });

  final String buttonId;
  final String actionText;
  final String title;
  final AlgorithmXData notificationData;
}

/// An impression, click, close, submit, or copy interaction was tracked.
class CampaignInteractionEvent {
  const CampaignInteractionEvent({
    required this.campaignId,
    required this.variationId,
    required this.interactionType,
    required this.payload,
  });

  final String campaignId;
  final String variationId;
  final String interactionType;
  final AlgorithmXData payload;
}

/// A parsed custom notification action.
///
/// [data] includes `parsedActionData`, a map created by the native SDK from
/// the notification's `actionData` JSON string.
class CustomActionEvent {
  const CustomActionEvent({required this.action, required this.data});

  final String? action;
  final AlgorithmXData data;
}

/// An action completed through the native notification router.
class ActionHandledEvent {
  const ActionHandledEvent({required this.action, required this.data});

  final String action;
  final AlgorithmXData data;
}
