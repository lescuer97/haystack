# Nayuki QR Code generator

Unmodified `c/qrcodegen.c` and `c/qrcodegen.h` from Project Nayuki,
https://github.com/nayuki/QR-Code-generator, v1.8.0,
commit `720f62bddb7226106071d4728c292cb1df519ceb`.
Both files contain the complete MIT license and copyright notice.

SHA-256:
- qrcodegen.c: `300eff07ee25baaa7578f20284411638154716379437391e7e689c0e6ce81403`
- qrcodegen.h: `e82df4bff37d18b5863b9e7486fe6bda1b6cda8c3b9ecebfec473907265cb589`

One C encoder is compiled into both the native and browser renderer. It performs
no network, heap allocation, or payment operations.

Portability: C99, fixed-width byte buffers and bounded integer arithmetic only;
no OS APIs, SIMD/assembly, pointer-size or host-endianness assumptions. Linux and
macOS ARM64 use LP64; Emscripten uses 32-bit `long`, which the upstream bounds
explicitly support. The same C ABI is used by Zig on both runtime platforms.

Checks (no toolchain installation):
- `zig build test-qr-portability -Doffline`: `-Wall -Wextra -Werror` C object
  cross-compilation for Linux x86_64, Linux aarch64 and macOS 15 ARM64. This is
  **not** an ARM64/macOS application link or runtime test.
- `zig build test -Doffline`: native suite includes QR encoding unit checks;
  these do not verify rendered images or independently decode them.
- `zig build test-wallet-ui -Dplatform=wasm -Doffline`: the actual Emscripten
  game exercises functional deposits, complete-invoice clipboard contents,
  exactly-once settlement and persisted history in disposable Chromium contexts.
  It does not check QR images, resizing or pixels.

The production renderer uses integer pixels and four quiet-zone modules, with
explicit unavailable messages for oversized invoices or undersized viewports.
There is no independent rendered-image decoding coverage. ARM64 Linux/macOS
require their own runtime runners; cross-compilation alone must not be described
as runtime verification.
