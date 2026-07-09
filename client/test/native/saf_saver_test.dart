import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:opaqueshare/native/saf_saver.dart';

/// Round-trips against the SAF plugin's method channel using
/// Flutter's `TestDefaultBinaryMessengerBinding`. We stand in for the
/// Kotlin side so both the happy path and the platform-exception
/// translation behavior lock in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.opaqueshare.app/saf_stream_save');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('SafSaveWriteException', () {
    test('carries the platform code + message for the receive screen to render',
        () {
      const exc = SafSaveWriteException(
        code: 'WRITE_FAILED',
        message: 'ENOSPC: no space left on device',
      );
      expect(exc.code, 'WRITE_FAILED');
      expect(exc.message, contains('ENOSPC'));
      expect(exc.toString(), contains('WRITE_FAILED'));
    });
  });

  group('MethodChannel SafSaver — pickSaveUri', () {
    test(
      'forwards suggestedFilename and returns URI + display name',
      () async {
        String? capturedFilename;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'pickSaveUri');
          capturedFilename =
              (call.arguments as Map<Object?, Object?>?)?['suggestedFilename']
                  as String?;
          return <String, String>{
            'uri': 'content://com.android.docs/tree/abc%2Freport.pdf',
            'displayName': 'report.pdf',
          };
        });

        final saf = SafSaver.methodChannelForTest();
        final result = await saf.pickSaveUri(
          suggestedFilename: 'report.pdf',
        );
        expect(capturedFilename, 'report.pdf');
        expect(result, isNotNull);
        expect(result!.uri, startsWith('content://'));
        expect(result.displayName, 'report.pdf');
      },
    );

    test(
      'falls back to suggestedFilename when Kotlin returns no displayName',
      () async {
        // Older DocumentsProviders can return a URI without a
        // queryable DISPLAY_NAME row. Rather than surface the raw
        // URI in the UI, [SafSaver] falls back to the same string
        // the user typed in the picker's title field.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
          return <String, String?>{
            'uri': 'content://legacy/doc/xyz',
            'displayName': null,
          };
        });

        final saf = SafSaver.methodChannelForTest();
        final result = await saf.pickSaveUri(
          suggestedFilename: 'the-name.zip',
        );
        expect(result?.displayName, 'the-name.zip');
      },
    );

    test('returns null when the user cancelled the picker', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);

      final saf = SafSaver.methodChannelForTest();
      final result = await saf.pickSaveUri(suggestedFilename: 'x.pdf');
      expect(result, isNull);
    });

    test('translates a PlatformException to SafSaveWriteException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'BUSY',
          message: 'Another pickSaveUri call is already in flight.',
        );
      });

      final saf = SafSaver.methodChannelForTest();
      await expectLater(
        saf.pickSaveUri(suggestedFilename: 'x.pdf'),
        throwsA(
          isA<SafSaveWriteException>()
              .having((e) => e.code, 'code', 'BUSY')
              .having((e) => e.message, 'message', contains('in flight')),
        ),
      );
    });
  });

  group('MethodChannel SafSaver — writeFileToUri', () {
    test('forwards sourcePath + uri and resolves on success', () async {
      Map<Object?, Object?>? capturedArgs;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'writeFileToUri');
        capturedArgs = call.arguments as Map<Object?, Object?>?;
        return null;
      });

      final saf = SafSaver.methodChannelForTest();
      await saf.writeFileToUri(
        sourcePath: '/data/user/0/pkg/cache/plain.tmp',
        uri: 'content://docs/tree/abc%2Fout.pdf',
      );
      expect(capturedArgs?['sourcePath'], '/data/user/0/pkg/cache/plain.tmp');
      expect(capturedArgs?['uri'], 'content://docs/tree/abc%2Fout.pdf');
    });

    test('translates a WRITE_FAILED PlatformException to typed exception',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'WRITE_FAILED',
          message: 'IOException: ENOSPC',
        );
      });

      final saf = SafSaver.methodChannelForTest();
      await expectLater(
        saf.writeFileToUri(sourcePath: '/tmp/a', uri: 'content://x'),
        throwsA(
          isA<SafSaveWriteException>()
              .having((e) => e.code, 'code', 'WRITE_FAILED')
              .having((e) => e.message, 'message', contains('ENOSPC')),
        ),
      );
    });
  });
}
