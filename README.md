[![pub package](https://img.shields.io/pub/v/pdfium_bindings.svg?style=for-the-badge)](https://pub.dartlang.org/packages/pdfium_bindings)

# pdfium_bindings

This project aims to wrap the complete [Pdfium](https://pdfium.googlesource.com/pdfium/) API in dart, over FFI.

# Low-level example:
```dart
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() {
  final stopwatch = Stopwatch()..start();
  final libraryPath = path.join(Directory.current.path, 'pdfium.dll');
  final dylib = DynamicLibrary.open(libraryPath);
  final pdfium = PDFiumBindings(dylib);

  const allocate = calloc;

  final config = allocate<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  config.ref.m_pUserFontPaths = nullptr;
  config.ref.m_pIsolate = nullptr;
  config.ref.m_v8EmbedderSlot = 0;
  pdfium.FPDF_InitLibraryWithConfig(config);

  final filePathP = stringToNativeInt8('1417.pdf');

  final doc = pdfium.FPDF_LoadDocument(filePathP, nullptr);
  if (doc == nullptr) {
    final err = pdfium.FPDF_GetLastError();
    throw PdfiumException.fromErrorCode(err);
  }

  final pageCount = pdfium.FPDF_GetPageCount(doc);
  print('pageCount: $pageCount');

  final page = pdfium.FPDF_LoadPage(doc, 0);
  if (page == nullptr) {
    final err = pdfium.getLastErrorMessage();
    pdfium.FPDF_CloseDocument(doc);
    throw PageException(message: err);
  }

  const scale = 1;
  final width = (pdfium.FPDF_GetPageWidth(page) * scale).round();
  final height = (pdfium.FPDF_GetPageHeight(page) * scale).round();

  print('page Width: $width');
  print('page Height: $height');

  // var backgroundStr = "FFFFFFFF"; // as int 268435455
  const background = 268435455;
  const startX = 0;
  final sizeX = width;
  const startY = 0;
  final sizeY = height;
  const rotate = 0;

  // Create empty bitmap and render page onto it
  // The bitmap always uses 4 bytes per pixel. The first byte is always
  // double word aligned.
  // The byte order is BGRx (the last byte unused if no alpha channel) or
  // BGRA. flags FPDF_ANNOT | FPDF_LCD_TEXT

  final bitmap = pdfium.FPDFBitmap_Create(width, height, 0);
  pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, background);
  pdfium.FPDF_RenderPageBitmap(
      bitmap, page, startX, startY, sizeX, sizeY, rotate, 0,);
  //  The pointer to the first byte of the bitmap buffer The data is in BGRA format
  final pointer = pdfium.FPDFBitmap_GetBuffer(bitmap);
  //stride = width * 4 bytes per pixel BGRA
  //var stride = pdfium.FPDFBitmap_GetStride(bitmap);
  //print('stride $stride');

  final Image image = Image.fromBytes(
      width: width,
      height: height,
      bytes: pointer.asTypedList(width * height * 4).buffer,
      order: ChannelOrder.bgra,
      numChannels: 4,
  );

  // save bitmap as PNG.
  File('out.png').writeAsBytesSync(encodePng(image));

  //clean
  pdfium.FPDFBitmap_Destroy(bitmap);

  pdfium.FPDF_ClosePage(page);
  allocate.free(filePathP);

  pdfium.FPDF_DestroyLibrary();
  allocate.free(config);

  print('end: ${stopwatch.elapsed}');
}

```
# High-level example:

```dart
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() {
  PdfiumWrap()
      .loadDocumentFromPath('1417.pdf')
      .loadPage(0)
      .savePageAsPng('out.png')
      .closePage()
      .closeDocument()
      .dispose();
}
```

# High-level example 2:
```dart
import 'package:http/http.dart' as http;
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() async {
  final pdfium = PdfiumWrap();

  final resp = await http.get(
    Uri.parse(
      'https://www.riodasostras.rj.gov.br/wp-content/uploads/2022/03/1426.pdf',
    ),
  );
  final bytes = resp.bodyBytes;

  pdfium
      .loadDocumentFromBytes(bytes)
      .loadPage(0)
      .savePageAsJpg('out.jpg', qualityJpg: 80)
      .closePage()
      .closeDocument()
      .dispose();
}
```

This has the potential to build a truly cross platform,
high-level API for rendering and editing PDFs on all 5 platforms.

## Goals

- [x] Build Pdfium shared libraries for all platforms. ([pdfium-binaries](https://github.com/bblanchon/pdfium-binaries))
- [x] Find a way to generate FFI code from C headers. ([ffigen](https://pub.dev/packages/ffigen))
- [ ] Integrate into [flutter_pdf_viewer](https://github.com/scientifichackers/flutter_pdf_viewer).

## Thanks
A [scientifichackers](https://github.com/scientifichackers/flutter-pdfium) for inspiring me 
<Br>
A big THANK YOU to Google for open sourcing Pdfium,
and releasing [dart:ffi](https://dart.dev/guides/libraries/c-interop).
