/// Lightweight Result type: `Ok(value)` or `Err(error)`.
///
/// Used everywhere the alternative would be a nullable + a companion error
/// string, or a thrown exception across an async boundary. Sealed so
/// exhaustive switches catch missed cases at compile time.
sealed class Result<T, E> {
  const Result();

  bool get isOk => this is Ok<T, E>;
  bool get isErr => this is Err<T, E>;

  T? get value => switch (this) {
        Ok<T, E>(:final value) => value,
        Err<T, E>() => null,
      };

  E? get error => switch (this) {
        Ok<T, E>() => null,
        Err<T, E>(:final error) => error,
      };
}

final class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  @override
  final T value;
}

final class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  @override
  final E error;
}
