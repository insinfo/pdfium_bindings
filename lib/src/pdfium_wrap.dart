import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/src/utils.dart';
import 'package:image/image.dart';

class PdfiumWrap {
  late PDFiumBindings pdfium;
  late Pointer<FPDF_LIBRARY_CONFIG> config;
  final Allocator allocator;
  Pointer<fpdf_document_t__>? _document;
  Pointer<fpdf_page_t__>? _page;
  Pointer<Uint8>? buffer;
  Pointer<fpdf_bitmap_t__>? bitmap;

  PdfiumWrap({String? libraryPath, this.allocator = calloc}) {
    //for windows
    var libPath = path.join(Directory.current.path, 'pdfium.dll');

    if (Platform.isMacOS) {
      libPath = path.join(Directory.current.path, 'libpdfium.dylib');
    } else if (Platform.isLinux || Platform.isAndroid) {
      libPath = path.join(Directory.current.path, 'libpdfium.so');
    }
    if (libraryPath != null) {
      libPath = libraryPath;
    }
    late DynamicLibrary dylib;
    if (Platform.isIOS) {
      DynamicLibrary.process();
    } else {
      dylib = DynamicLibrary.open(libPath);
    }
    pdfium = PDFiumBindings(dylib);

    config = allocator<FPDF_LIBRARY_CONFIG>();
    config.ref.version = 2;
    config.ref.m_pUserFontPaths = nullptr;
    config.ref.m_pIsolate = nullptr;
    config.ref.m_v8EmbedderSlot = 0;
    pdfium.FPDF_InitLibraryWithConfig(config);
  }

  PdfiumWrap loadDocumentFromPath(String path, {String? password}) {
    var filePathP = stringToNativeInt8(path);
    _document = pdfium.FPDF_LoadDocument(
        filePathP, password != null ? stringToNativeInt8(password) : nullptr);
    if (_document == nullptr) {
      var err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }
    return this;
  }

  PdfiumWrap loadDocumentFromBytes(Uint8List bytes, {String? password}) {
    // Allocate a pointer large enough.
    final frameData = allocator<Uint8>(bytes.length);
    // Create a list that uses our pointer and copy in the image data.
    final pointerList = frameData.asTypedList(bytes.length);
    pointerList.setAll(0, bytes);

    _document = pdfium.FPDF_LoadMemDocument64(
        frameData.cast<Void>(),
        bytes.length,
        password != null ? stringToNativeInt8(password) : nullptr);

    if (_document == nullptr) {
      var err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }
    return this;
  }

  PdfiumWrap loadPage(int index) {
    if (_document == nullptr) {
      throw PdfiumException(message: 'Document not load');
    }
    _page = pdfium.FPDF_LoadPage(_document!, index);
    if (_page == nullptr) {
      var err = pdfium.getLastErrorMessage();
      throw PageException(message: err);
    }
    return this;
  }

  int getPageCount() {
    if (_document == nullptr) {
      throw PdfiumException(message: 'Document not load');
    }
    return pdfium.FPDF_GetPageCount(_document!);
  }

  double getPageWidth() {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    return pdfium.FPDF_GetPageWidth(_page!);
  }

  double getPageHeight() {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    return pdfium.FPDF_GetPageHeight(_page!);
  }

  /// Create empty bitmap and render page onto it
  /// The bitmap always uses 4 bytes per pixel. The first byte is always
  /// double word aligned.
  /// The byte order is BGRx (the last byte unused if no alpha channel) or
  /// BGRA. flags FPDF_ANNOT | FPDF_LCD_TEXT
  Uint8List renderPageAsBytes(int width, int height,
      {int backgroundColor = 268435455, int rotate = 0, int flags = 0}) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    var w = width;
    var h = height;
    var start_x = 0;
    var size_x = w;
    var start_y = 0;
    var size_y = h;

    // Create empty bitmap and render page onto it
    // The bitmap always uses 4 bytes per pixel. The first byte is always
    // double word aligned.
    // The byte order is BGRx (the last byte unused if no alpha channel) or
    // BGRA. flags FPDF_ANNOT | FPDF_LCD_TEXT

    bitmap = pdfium.FPDFBitmap_Create(w, h, 0);
    pdfium.FPDFBitmap_FillRect(bitmap!, 0, 0, w, h, backgroundColor);
    pdfium.FPDF_RenderPageBitmap(
        bitmap!, _page!, start_x, start_y, size_x, size_y, rotate, flags);
    //  The pointer to the first byte of the bitmap buffer The data is in BGRA format
    buffer = pdfium.FPDFBitmap_GetBuffer(bitmap!);
    //stride = width * 4 bytes per pixel BGRA
    //var stride = pdfium.FPDFBitmap_GetStride(bitmap);
    //print('stride $stride');
    var list = buffer!.asTypedList(w * h * 4);

    return list;
  }

  PdfiumWrap savePageAsPng(String outPath,
      {int? width,
      int? height,
      int backgroundColor = 268435455,
      double scale = 1,
      int rotate = 0,
      int flags = 0,
      bool flush = false,
      int pngLevel = 6}) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    var w = ((width ?? getPageWidth()) * scale).round();
    var h = ((height ?? getPageHeight()) * scale).round();

    var bytes = renderPageAsBytes(w, h,
        backgroundColor: backgroundColor, rotate: rotate, flags: flags);

    var image = Image.fromBytes(w, h, bytes,
        format: Format.bgra, channels: Channels.rgba);

    // save bitmap as PNG.
    File(outPath)
        .writeAsBytesSync(encodePng(image, level: pngLevel), flush: flush);
    return this;
  }

  PdfiumWrap savePageAsJpg(String outPath,
      {int? width,
      int? height,
      int backgroundColor = 268435455,
      double scale = 1,
      int rotate = 0,
      int flags = 0,
      bool flush = false,
      int qualityJpg = 100}) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    var w = ((width ?? getPageWidth()) * scale).round();
    var h = ((height ?? getPageHeight()) * scale).round();

    var bytes = renderPageAsBytes(w, h,
        backgroundColor: backgroundColor, rotate: rotate, flags: flags);

    var image = Image.fromBytes(w, h, bytes,
        format: Format.bgra, channels: Channels.rgba);

    // save bitmap as PNG.
    File(outPath)
        .writeAsBytesSync(encodeJpg(image, quality: qualityJpg), flush: flush);
    return this;
  }

  PdfiumWrap closePage() {
    if (_page != null && _page != nullptr) {
      pdfium.FPDF_ClosePage(_page!);

      if (bitmap != null && bitmap != nullptr) {
        pdfium.FPDFBitmap_Destroy(bitmap!);
      }
    }
    return this;
  }

  PdfiumWrap closeDocument() {
    if (_document != null && _document != nullptr) {
      pdfium.FPDF_CloseDocument(_document!);
    }
    return this;
  }

  void dispose() {
    closePage();
    closeDocument();
    pdfium.FPDF_DestroyLibrary();
    allocator.free(config);
  }
}
