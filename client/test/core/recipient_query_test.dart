import 'package:flutter_test/flutter_test.dart';
import 'package:opaqueshare/core/recipient_query.dart';

void main() {
  group('RecipientQuery.parse', () {
    test('routes a leading-@ handle to the handle branch, sigil stripped', () {
      // The regression this class exists for: the "To" field is labelled
      // "Email or @handle", but the old `contains('@')` heuristic sent
      // `@alice` to the email branch, where the server's EmailStr
      // rejected it with a 422.
      final q = RecipientQuery.parse('@alice');
      expect(q, isNotNull);
      expect(q!.isEmail, isFalse);
      expect(q.value, 'alice');
    });

    test('routes an address to the email branch, unmodified', () {
      final q = RecipientQuery.parse('alice@example.com');
      expect(q!.isEmail, isTrue);
      expect(q.value, 'alice@example.com');
    });

    test('routes a bare name to the handle branch', () {
      final q = RecipientQuery.parse('alice');
      expect(q!.isEmail, isFalse);
      expect(q.value, 'alice');
    });

    test('trims surrounding whitespace before classifying', () {
      expect(RecipientQuery.parse('  @alice  ')!.value, 'alice');
      expect(
        RecipientQuery.parse('  alice@example.com ')!.value,
        'alice@example.com',
      );
      expect(RecipientQuery.parse(' alice ')!.value, 'alice');
    });

    test('returns null for empty or whitespace-only input', () {
      expect(RecipientQuery.parse(''), isNull);
      expect(RecipientQuery.parse('   '), isNull);
      expect(RecipientQuery.parse('\t\n'), isNull);
    });

    test('returns null for a lone @ — no handle to look up', () {
      expect(RecipientQuery.parse('@'), isNull);
      expect(RecipientQuery.parse('  @  '), isNull);
    });

    test('a subdomain address still routes to email', () {
      final q = RecipientQuery.parse('alice@mail.example.co.uk');
      expect(q!.isEmail, isTrue);
      expect(q.value, 'alice@mail.example.co.uk');
    });

    test('plus-addressing survives untouched', () {
      // Local validation is deliberately absent — the server owns
      // address validation, and a stricter client regex would reject
      // addresses that are actually deliverable.
      final q = RecipientQuery.parse('alice+opaqueshare@example.com');
      expect(q!.isEmail, isTrue);
      expect(q.value, 'alice+opaqueshare@example.com');
    });

    test('an @-prefixed address is treated as a handle, not an email', () {
      // Ambiguous input. Documenting the choice rather than asserting
      // it is obviously right: the leading sigil is the stronger signal
      // of intent, and the server will 404 a handle that looks like an
      // address, which is a clearer outcome than a 422.
      final q = RecipientQuery.parse('@alice@example.com');
      expect(q!.isEmail, isFalse);
      expect(q.value, 'alice@example.com');
    });
  });
}
