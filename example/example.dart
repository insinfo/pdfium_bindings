// ignore_for_file: avoid_print

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
