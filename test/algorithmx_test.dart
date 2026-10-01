import 'package:algorithmx_flutter/algorithmx_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MethodChannel channel;
  late AlgorithmX sdk;

  setUp(() {
    // Each test gets a unique channel so its native mock cannot leak into a
    // later test or interfere with the public AlgorithmX.instance channel.
    channel = MethodChannel(
      'algorithmx_flutter/test/${DateTime.now().microsecondsSinceEpoch}',
    );
    sdk = AlgorithmX.forTesting(channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    sdk.clearHandlers();
  });

  test('initialize forwards a named URL argument', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await sdk.initialize(apiBaseUrl: 'https://example.com');

    expect(received?.method, 'initialize');
    expect(received?.arguments, {'apiBaseUrl': 'https://example.com'});
  });

  test(
    'tracking passes nested properties and optional campaign fields',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });

      await sdk.trackEvent(
        'purchase',
        properties: {
          'amount': 19.95,
          'items': [
            {'sku': 'A1', 'quantity': 1},
          ],
        },
      );
      await sdk.trackCampaignInteraction(
        campaignId: '4',
        variationId: '8',
        interactionType: 'click',
        payload: {'source': 'flutter'},
        sessionId: 'session-1',
        endpoint: '/api/v1/tracks/algo_view_interact',
      );

      expect(calls.map((call) => call.method), [
        'trackEvent',
        'trackCampaignInteraction',
      ]);
      expect((calls.first.arguments as Map)['properties'], {
        'amount': 19.95,
        'items': [
          {'sku': 'A1', 'quantity': 1},
        ],
      });
      expect((calls.last.arguments as Map)['sessionId'], 'session-1');
      expect(
        (calls.last.arguments as Map)['endpoint'],
        '/api/v1/tracks/algo_view_interact',
      );
    },
  );

  test('notification status uses the native wire code', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      received = call;
      return null;
    });

    await sdk.updateNotificationStatus(
      12,
      NotificationEventStatus.failedToDeliver,
      errorMessage: 'offline',
    );

    expect(received?.method, 'updateNotificationStatus');
    expect(received?.arguments, {
      'notificationId': 12,
      'status': 5,
      'errorMessage': 'offline',
    });
  });

  test('notification click awaits the app decision', () async {
    sdk.onNotificationClick = (data) async {
      await Future<void>.delayed(Duration.zero);
      return data['action_type'] == 'open_screen';
    };

    final result = await sdk.handleNativeCall(
      const MethodCall('onNotificationClick', {
        'data': {'action_type': 'open_screen'},
      }),
    );

    expect(result, isTrue);
  });

  test('missing bool callback returns false for native fallback', () async {
    final result = await sdk.handleNativeCall(
      const MethodCall('onActionButtonClicked', {
        'buttonId': 'view',
        'actionText': 'view_offer',
        'title': 'View offer',
        'notificationData': {'algo_campaign_id': '4'},
      }),
    );

    expect(result, isFalse);
  });

  test('webview event preserves dynamic content as a nested map', () async {
    final nextEvent = sdk.webViewTriggers.first;
    await sdk.handleNativeCall(
      const MethodCall('onWebViewTrigger', {
        'campaignId': '4',
        'webviewUrl': 'https://example.com/campaign',
        'dynamicContent': {
          'customer': {'name': 'Ava'},
        },
      }),
    );

    final event = await nextEvent;
    expect(event.campaignId, '4');
    expect(event.webviewUrl, 'https://example.com/campaign');
    expect(event.dynamicContent, {
      'customer': {'name': 'Ava'},
    });
  });

  test('direct deep link returns the Dart handler result once', () async {
    var calls = 0;
    sdk.onDeepLink = (url) {
      calls++;
      return url == 'myapp://cart';
    };

    expect(await sdk.openDeepLink('myapp://cart'), isTrue);
    expect(calls, 1);
  });
}
