[![pub package](https://img.shields.io/pub/v/pdfium_bindings.svg?style=for-the-badge)](https://pub.dev/packages/pdfium_bindings)

# pdfium_bindings

High-level and low-level [PDFium](https://pdfium.googlesource.com/pdfium/) bindings for Dart and Flutter via `dart:ffi`.

## Highlights

- `PdfiumWrap` provides a safe, finalizer-backed API for loading documents, pages, and rendering output.
- Configurable via `PdfiumConfig`, including library location, font paths, and V8 embedder slot support.
- Built-in helpers for BGRA buffers, PNG/JPEG export, sub-region rendering, and isolate-based image rendering.
- Includes page extraction and merge helpers built on top of the low-level editing APIs.
- Ships with the generated low-level bindings when you need direct access to the PDFium C API.

## Installation

```bash
dart pub add pdfium_bindings
```

You also need a matching native PDFium binary alongside your app. Grab a prebuilt library from
[pdfium-binaries](https://github.com/bblanchon/pdfium-binaries) (or build your own) and copy the
appropriate file next to your executable (for example `pdfium.dll`, `libpdfium.so`, or `libpdfium.dylib`).

## Quick start

```dart
import 'package:pdfium_bindings/pdfium_bindings.dart';

Future<void> main() async {
  final wrapper = PdfiumWrap(
    config: const PdfiumConfig(libraryPath: 'pdfium.dll'),
  );

  wrapper
      .loadDocumentFromPath('1417.pdf')
      .loadPage(0)
      .savePageAsPng('out.png')
      .closeDocument()
      .dispose();
}
```

## Async rendering helper

```dart
final image = await PdfiumWrap.renderPageToImageAsync(
  config: const PdfiumConfig(libraryPath: 'pdfium.dll'),
  documentPath: '1417.pdf',
  pageIndex: 0,
  scale: 1.5,
);

print('Rendered ${image.width}x${image.height}');
```

## Page extraction and merging

```dart
await PdfiumWrap.extractPagesFromFile(
  config: const PdfiumConfig(libraryPath: 'pdfium.dll'),
  sourcePath: 'source.pdf',
  outputPath: 'page_1.pdf',
  pageIndices: const [0],
);

await PdfiumWrap.mergeDocuments(
  config: const PdfiumConfig(libraryPath: 'pdfium.dll'),
  sources: [
    PdfMergeSource(documentPath: 'first.pdf', pageRange: '1-2'),
    PdfMergeSource(documentPath: 'second.pdf', pageIndices: const [0]),
  ],
  outputPath: 'merged.pdf',
);
```

## Managing isolate contention

When several isolates need to touch the same PDFium instance you can choose between two locking helpers:

- **File-backed lock (`_FileMutex`)**
  - ✅ Allows `await` inside the critical section—the OS keeps the file lock while the future runs.
  - ✅ Coordinates across different processes (multiple `dart` executables) because the lock lives in the filesystem.
  - ❌ Slower and more fragile; it depends on filesystem permissions, temp directories, and platform quirks.
  - ❌ Opens and closes a file on every call.
  - ❌ Adds disk I/O around native code that was not designed for it.
- **`native_synchronization` mutex (`PdfiumServiceMutex`)**
  - ✅ Tailored for multiple isolates inside the same process—exactly the PDFium contention scenario.
  - ✅ No disk I/O and minimal overhead.
  - ✅ Share the mutex via `asSendable` so every isolate contends for the same lock explicitly.
  - ✅ Clear flow: enter `runLocked`, finish, release.
  - ❌ The critical section must remain synchronous (no `await`).
  - ❌ Cannot coordinate multiple processes.

For most “many isolates, one PDFium DLL” cases, prefer `PdfiumServiceMutex`. Switch to the file-backed lock only when you truly need cross-process coordination or asynchronous work while holding the mutex.

## Low-level access

Need the raw C API? Import `pdfium_bindings/src/pdfium_bindings.dart` and work with the generated
structures directly. The repo still ships the original low-level example in `example/example2.dart`.

## Development

- `dart analyze`
- `dart test`
- `dart run ffigen --config ffigen.yaml` (regenerate the bindings)

## Goals

- [x] Provide ready-to-use high-level helpers on top of PDFium.
- [x] Expose generated bindings for advanced users.
- [ ] Integrate with higher-level Flutter widgets.

## Thanks

- [scientifichackers/flutter-pdfium](https://github.com/scientifichackers/flutter-pdfium) for the inspiration.
- Google for open sourcing PDFium and enabling first-class native interop via [dart:ffi](https://dart.dev/guides/libraries/c-interop).
