import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:opaqueshare/features/verify_contact/verified_contacts_repo.dart';
import 'package:opaqueshare/storage/secure_storage.dart';

class _FakeStore extends Mock implements SecureStore {}

void main() {
  late _FakeStore store;
  late VerifiedContactsRepo repo;

  setUp(() {
    store = _FakeStore();
    repo = VerifiedContactsRepo(store);
    when(() => store.write(any(), any())).thenAnswer((_) async {});
    when(() => store.read(any())).thenAnswer((_) async => null);
    when(() => store.delete(any())).thenAnswer((_) async {});
  });

  test('markVerified writes {fp, at} JSON under a namespaced key', () async {
    final at = DateTime.utc(2026, 7, 1, 12);
    await repo.markVerified(
      userId: 'u-1',
      canonical: '0000000583409474571453372',
      at: at,
    );

    final captured = verify(() => store.write('vc.u-1', captureAny()))
        .captured
        .single as String;
    expect(captured, contains('0000000583409474571453372'));
    expect(captured, contains(at.toIso8601String()));
  });

  test('read returns null when nothing is stored', () async {
    when(() => store.read('vc.u-1')).thenAnswer((_) async => null);
    expect(await repo.read('u-1'), isNull);
  });

  test('read parses back the stored payload', () async {
    when(() => store.read('vc.u-1')).thenAnswer(
      (_) async =>
          '{"fp":"0000000583409474571453372","at":"2026-07-01T12:00:00.000Z"}',
    );
    final vc = await repo.read('u-1');
    expect(vc, isNotNull);
    expect(vc!.canonical, '0000000583409474571453372');
    expect(vc.at.toUtc().year, 2026);
  });

  test('read tolerates a corrupted payload by returning null', () async {
    when(() => store.read('vc.u-1'))
        .thenAnswer((_) async => 'not-valid-json{');
    expect(await repo.read('u-1'), isNull);
  });

  test('forget deletes the underlying key', () async {
    await repo.forget('u-1');
    verify(() => store.delete('vc.u-1')).called(1);
  });
}
