import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:nduzem/api/api_client.dart';
import 'package:nduzem/api/users_api.dart';
import 'package:nduzem/crypto/plaintext_source.dart';
import 'package:nduzem/features/auth/auth_providers.dart';
import 'package:nduzem/features/history/transfer_history_provider.dart';
import 'package:nduzem/features/history/transfer_history_repository.dart';
import 'package:nduzem/features/transfers/picked_file.dart';
import 'package:nduzem/features/transfers/send_queue.dart';
import 'package:nduzem/features/transfers/transfer_service.dart';

class _FakeTransferService extends Fake implements TransferService {}

class _MockTransferService extends Mock implements TransferService {}

class _FakeCancelToken extends Fake implements CancelToken {}

class _FakePlaintextSource extends Fake implements PlaintextSource {}

UserLookup _lookup() => UserLookup(
      userId: 'u-recipient',
      identityPublic: Uint8List.fromList(List<int>.filled(32, 1)),
      signingPublic: Uint8List.fromList(List<int>.filled(32, 2)),
      serverKeyFingerprint: '00000 00583 40947 45714 53372',
    );

PickedFile _picked(String name, {int length = 4096}) => PickedFile(
      source: FilePlaintextSource(
        path: '/tmp/$name',
        filename: name,
        lengthBytes: length,
        mimeType: 'application/octet-stream',
      ),
      name: name,
      mime: 'application/octet-stream',
      length: length,
    );

SendResult _successResult(String transferId, {int byteCountOnServer = 4096}) {
  return SendResult(
    mode: SendMode.app,
    transferId: transferId,
    byteCountOnServer: byteCountOnServer,
    status: 'uploaded',
  );
}

/// Build a container that overrides both the transfer service (with
/// `service`) and the history repository (with a real repo pointed at
/// [tmp] so `.log()` writes don't touch the real app-docs dir). ADR-0012:
/// the repo needs a `userId` to actually write anything.
const String _testUid = 'u-tester';

ProviderContainer _container(TransferService service, Directory tmp) {
  return ProviderContainer(
    overrides: [
      transferServiceProvider.overrideWith((ref) async => service),
      transferHistoryRepositoryProvider.overrideWith(
        (_) => TransferHistoryRepository(
          userId: _testUid,
          directoryOverride: tmp,
        ),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(_FakeCancelToken());
    registerFallbackValue(SendMode.app);
    // ADR-0013: send() now takes a `PlaintextSource` in place of the
    // old plaintextPath/length/filename/mime quartet. Mocktail needs
    // a fallback for the type when `any(named: 'source')` is used.
    registerFallbackValue(_FakePlaintextSource());
  });

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('opq-queue-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('empty file list produces a done batch with no items', () async {
    final svc = _MockTransferService();
    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: const <PickedFile>[],
    );

    final state = container.read(sendQueueProvider);
    expect(state, isNotNull);
    expect(state!.items, isEmpty);
    expect(state.isDone, isTrue);
    expect(state.doneCount, 0);
  });

  test('single-file batch reports one done item + logs history', () async {
    final svc = _MockTransferService();
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async => _successResult('t-1'));

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf')],
    );

    final state = container.read(sendQueueProvider)!;
    expect(state.isDone, isTrue);
    expect(state.doneCount, 1);
    expect(state.items.single.status, QueueItemStatus.done);
    expect(state.items.single.transferId, 't-1');
    // History entry got logged — the repository under tmp has one row.
    // Read back through a repo scoped to the same user id the override
    // used, so the scoped file is found.
    final entries = await TransferHistoryRepository(
      userId: _testUid,
      directoryOverride: tmp,
    ).readAll();
    expect(entries, hasLength(1));
    expect(entries.single.transferId, 't-1');
  });

  test('three-file batch: all succeed, all done in order', () async {
    final svc = _MockTransferService();
    var call = 0;
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async => _successResult('t-${call++}'));

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf'), _picked('b.pdf'), _picked('c.pdf')],
    );

    final state = container.read(sendQueueProvider)!;
    expect(state.doneCount, 3);
    expect(state.failedCount, 0);
    expect(
      state.items.map((i) => i.transferId).toList(),
      ['t-0', 't-1', 't-2'],
    );
  });

  test('mid-batch failure is per-item — remaining files still send',
      () async {
    final svc = _MockTransferService();
    var call = 0;
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {
      final idx = call++;
      if (idx == 1) {
        throw ApiException(statusCode: 500, message: 'server barfed');
      }
      return _successResult('t-$idx');
    });

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf'), _picked('b.pdf'), _picked('c.pdf')],
    );

    final state = container.read(sendQueueProvider)!;
    expect(state.doneCount, 2);
    expect(state.failedCount, 1);
    expect(state.items[0].status, QueueItemStatus.done);
    expect(state.items[1].status, QueueItemStatus.failed);
    expect(state.items[1].errorMessage, 'server barfed');
    expect(state.items[2].status, QueueItemStatus.done);
  });

  test('QuotaExceededException halts the batch and cancels remaining',
      () async {
    final svc = _MockTransferService();
    var call = 0;
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async {
      final idx = call++;
      if (idx == 1) {
        throw QuotaExceededException(
          requiredMb: 5000,
          subRemainingMb: 100,
          creditMb: 0,
        );
      }
      return _successResult('t-$idx');
    });

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf'), _picked('b.pdf'), _picked('c.pdf')],
    );

    final state = container.read(sendQueueProvider)!;
    expect(state.doneCount, 1);
    expect(state.failedCount, 1);
    expect(state.cancelledCount, 1);
    expect(state.items[1].status, QueueItemStatus.failed);
    expect(state.items[2].status, QueueItemStatus.cancelled);
    expect(state.items[2].errorMessage, contains('balance exhausted'));
    // The exception itself rides on state so the batch screen can
    // render the paywall CTA.
    expect(state.quotaError, isNotNull);
    expect(state.quotaError!.requiredMb, 5000);
  });

  test('cancel drops the queue and marks pending items cancelled', () async {
    final svc = _MockTransferService();
    // First send hangs on a Completer we control from the test so the
    // batch is definitively "in flight" when we invoke cancel().
    final firstStarted = Completer<void>();
    final firstShouldFinish = Completer<SendResult>();
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((invocation) {
      if (!firstStarted.isCompleted) firstStarted.complete();
      return firstShouldFinish.future;
    });

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    // Kick off but don't await — the first send is stuck.
    final batch = container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf'), _picked('b.pdf'), _picked('c.pdf')],
    );
    await firstStarted.future;

    // Verify the queue is running and item 1/2 are pending.
    var state = container.read(sendQueueProvider)!;
    expect(state.isRunning, isTrue);
    expect(state.items[1].status, QueueItemStatus.pending);
    expect(state.items[2].status, QueueItemStatus.pending);

    // Cancel and let the in-flight send resolve as if the CancelToken
    // fired.
    container.read(sendQueueProvider.notifier).cancel();
    firstShouldFinish.completeError(const SendCancelledException());
    await batch;

    state = container.read(sendQueueProvider)!;
    expect(state.cancelled, isTrue);
    expect(state.items[0].status, QueueItemStatus.cancelled);
    expect(state.items[1].status, QueueItemStatus.cancelled);
    expect(state.items[2].status, QueueItemStatus.cancelled);
  });

  test('reset() clears the state back to null', () async {
    final svc = _MockTransferService();
    when(
      () => svc.send(
        mode: any(named: 'mode'),
        recipient: any(named: 'recipient'),
        source: any(named: 'source'),
        linkPassword: any(named: 'linkPassword'),
        recipientEmail: any(named: 'recipientEmail'),
        maxDownloads: any(named: 'maxDownloads'),
        onProgress: any(named: 'onProgress'),
        cancel: any(named: 'cancel'),
      ),
    ).thenAnswer((_) async => _successResult('t-x'));

    final container = _container(svc, tmp);
    addTearDown(container.dispose);

    await container.read(sendQueueProvider.notifier).start(
      recipient: _lookup(),
      recipientLabel: 'alice@example.com',
      files: [_picked('a.pdf')],
    );
    expect(container.read(sendQueueProvider), isNotNull);

    container.read(sendQueueProvider.notifier).reset();
    expect(container.read(sendQueueProvider), isNull);
  });
}

// Suppress "unused" warning on the Fake helper that mocktail
// registration might need for fallback values in the future.
// ignore: unused_element
final _fakeService = _FakeTransferService();
