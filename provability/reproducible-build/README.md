# Reproducible builds (spec 13.1)
Pin toolchain (Flutter/Dart SDK, deps, flags); hermetic CI. Publish a per-release
build manifest: source commit, lockfile hashes, binary hash. verify.sh lets any
third party confirm the store binary matches public source.
