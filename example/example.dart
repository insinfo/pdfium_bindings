import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/src/utils.dart';
import 'package:image/image.dart';

void main() {
  //var libraryPath = 'C:\MyDartProjects\pdfium\pdfium-binaries\win\bin\pdfium.dll';
  // C:\Program Files (x86)\Microsoft Visual Studio\2019\Community>dumpbin /dependents C:\MyDartProjects\pdfium\pdfium-binaries\win\bin\pdfium.dll
  var stopwatch = Stopwatch()..start();
  var libraryPath = path.join(Directory.current.path, 'pdfium.dll');
  final dylib = DynamicLibrary.open(libraryPath);
  var pdfium = PDFiumBindings(dylib);

  var allocate = calloc;

  final config = allocate<FPDF_LIBRARY_CONFIG>();
  config.ref.version = 2;
  config.ref.m_pUserFontPaths = nullptr;
  config.ref.m_pIsolate = nullptr;
  config.ref.m_v8EmbedderSlot = 0;
  pdfium.FPDF_InitLibraryWithConfig(config);

  var filePathP = stringToNativeInt8('1417.pdf');

  var doc = pdfium.FPDF_LoadDocument(filePathP, nullptr);
  if (doc == nullptr) {
    var err = pdfium.FPDF_GetLastError();
    throw PdfiumException.fromErrorCode(err);
  }

  var pageCount = pdfium.FPDF_GetPageCount(doc);
  print('pageCount: $pageCount');

  var page = pdfium.FPDF_LoadPage(doc, 0);
  if (page == nullptr) {
    var err = pdfium.getLastErrorMessage();
    pdfium.FPDF_CloseDocument(doc);
    throw PageException(message: err);
  }

  var scale = 1;
  var width = (pdfium.FPDF_GetPageWidth(page) * scale).round();
  var height = (pdfium.FPDF_GetPageHeight(page) * scale).round();

  print('page Width: $width');
  print('page Height: $height');

  // var backgroundStr = "FFFFFFFF"; // as int 268435455
  var background = 268435455;
  var start_x = 0;
  var size_x = width;
  var start_y = 0;
  var size_y = height;
  var rotate = 0;

  // Create empty bitmap and render page onto it
  // The bitmap always uses 4 bytes per pixel. The first byte is always
  // double word aligned.
  // The byte order is BGRx (the last byte unused if no alpha channel) or
  // BGRA. flags FPDF_ANNOT | FPDF_LCD_TEXT

  var bitmap = pdfium.FPDFBitmap_Create(width, height, 0);
  pdfium.FPDFBitmap_FillRect(bitmap, 0, 0, width, height, background);
  pdfium.FPDF_RenderPageBitmap(
      bitmap, page, start_x, start_y, size_x, size_y, rotate, 0);
  //  The pointer to the first byte of the bitmap buffer The data is in BGRA format
  var pointer = pdfium.FPDFBitmap_GetBuffer(bitmap);
  //stride = width * 4 bytes per pixel BGRA
  //var stride = pdfium.FPDFBitmap_GetStride(bitmap);
  //print('stride $stride');

  var image = Image.fromBytes(
      width, height, pointer.asTypedList(width * height * 4),
      format: Format.bgra, channels: Channels.rgba);

  // save bitmap as PNG.
  File('out.png').writeAsBytesSync(encodePng(image));

  //clean
  pdfium.FPDFBitmap_Destroy(bitmap);

  pdfium.FPDF_ClosePage(page);
  allocate.free(filePathP);

  pdfium.FPDF_DestroyLibrary();
  //allocate.free(config);

  print('end: ${stopwatch.elapsed}');
}
