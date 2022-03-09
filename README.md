[![pub package](https://img.shields.io/pub/v/pdfium.svg?style=for-the-badge)](https://pub.dartlang.org/packages/pdfium)

# Flutter Pdfium

This project aims to wrap the complete [Pdfium](https://pdfium.googlesource.com/pdfium/) API in dart, over FFI.



This has the potential to build a truly cross platform,
high-level API for rendering and editing PDFs on all 5 platforms.

## Goals

- [x] Build Pdfium shared libraries for all platforms. ([pdfium_builder](https://github.com/scientifichackers/pdfium-builder))
- [x] Find a way to generate FFI code from C headers.
- [ ] Integrate into [flutter_pdf_viewer](https://github.com/scientifichackers/flutter_pdf_viewer).

## Thanks

A big THANK YOU to Google for open sourcing Pdfium,
and releasing [dart:ffi](https://dart.dev/guides/libraries/c-interop).
