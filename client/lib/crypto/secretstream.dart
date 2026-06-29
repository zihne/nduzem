// Chunked AEAD for large files: crypto_secretstream_xchacha20poly1305 (spec 5.4).
// ~4MB chunks; TAG_FINAL on last chunk prevents truncation attacks.
