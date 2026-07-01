import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/core/result.dart';

void main() {
  test('Ok exposes value and reports isOk', () {
    const r = Ok<int, String>(42);
    expect(r.isOk, isTrue);
    expect(r.isErr, isFalse);
    expect(r.value, 42);
    expect(r.error, isNull);
  });

  test('Err exposes error and reports isErr', () {
    const r = Err<int, String>('boom');
    expect(r.isOk, isFalse);
    expect(r.isErr, isTrue);
    expect(r.value, isNull);
    expect(r.error, 'boom');
  });

  test('exhaustive switch works because Result is sealed', () {
    String describe(Result<int, String> r) => switch (r) {
          Ok(:final value) => 'ok=$value',
          Err(:final error) => 'err=$error',
        };
    expect(describe(const Ok(1)), 'ok=1');
    expect(describe(const Err('x')), 'err=x');
  });
}
