import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:mobile_scanner/src/method_channel/mobile_scanner_method_channel.dart';

class _PreviewPlatform extends MethodChannelMobileScanner {
  final events = StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> get eventsStream => events.stream;
}

void main() {
  testWidgets(
    'freeze, restart and forced stop preserve the preview lifecycle',
    (tester) async {
      final MobileScannerPlatform original = MobileScannerPlatform.instance;
      final platform = _PreviewPlatform();
      MobileScannerPlatform.instance = platform;
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        platform.methodChannel,
        (call) async {
          calls.add(call);
          return switch (call.method) {
            'state' => 1,
            'start' => {
              'textureId': 1,
              'cameraDirection': 1,
              'currentTorchState': 0,
              'size': {'width': 1280.0, 'height': 720.0},
            },
            _ => null,
          };
        },
      );
      final controller = MobileScannerController(autoStart: false);
      var frames = 0;
      final StreamSubscription<void> subscription = controller
          .previewStartedStream
          .listen((_) => frames++);
      addTearDown(() async {
        await subscription.cancel();
        await controller.dispose();
        await platform.events.close();
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          platform.methodChannel,
          null,
        );
        MobileScannerPlatform.instance = original;
      });

      await tester.pumpWidget(
        MaterialApp(home: MobileScanner(controller: controller)),
      );
      await controller.start();
      platform.events.add({'name': 'previewStarted', 'data': null});
      await tester.pump();
      expect(frames, 1);
      expect(tester.widget<Texture>(find.byType(Texture)).freeze, isFalse);

      await controller.freezePreview();
      await tester.pump();
      expect(controller.value.isRunning, isFalse);
      expect(tester.widget<Texture>(find.byType(Texture)).freeze, isTrue);

      await controller.start();
      platform.events.add({'name': 'previewStarted', 'data': null});
      await tester.pump();
      expect(frames, 2);
      expect(controller.value.isRunning, isTrue);
      expect(tester.widget<Texture>(find.byType(Texture)).freeze, isFalse);

      await controller.freezePreview();
      await controller.stop(force: true);
      await tester.pump();
      expect(controller.value.frozen, isFalse);
      expect(find.byType(Texture), findsNothing);
      expect(
        calls
            .where((call) => ['start', 'pause', 'stop'].contains(call.method))
            .map((call) => call.method),
        // The widget first releases any camera left over from a hot restart.
        ['stop', 'start', 'pause', 'start', 'pause', 'stop'],
      );
      expect(calls.last.arguments, {'force': true});
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );
}
