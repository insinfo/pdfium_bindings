import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/pdfium_bindings.dart';

/// Wrapper class to abstract the PDFium logic
class PdfiumWrap {
  /// Bindings to PDFium
  late PDFiumBindings pdfium;

  /// PDFium configuration
  late Pointer<FPDF_LIBRARY_CONFIG> config;
  final Allocator allocator;
  Pointer<fpdf_document_t__>? _document;
  Pointer<fpdf_page_t__>? _page;
  Pointer<Uint8>? buffer;
  Pointer<fpdf_bitmap_t__>? bitmap;

  /// Default constructor to use the class, note that if [dylib] field is
  /// specified, it will override the library path.
  PdfiumWrap({
    String? libraryPath,
    this.allocator = calloc,
    DynamicLibrary? dylib,
  }) {
    //for windows
    if (dylib == null) {
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
    } else {
      pdfium = PDFiumBindings(dylib);
    }

    config = allocator<FPDF_LIBRARY_CONFIG>();
    config.ref.version = 2;
    config.ref.m_pUserFontPaths = nullptr;
    config.ref.m_pIsolate = nullptr;
    config.ref.m_v8EmbedderSlot = 0;
    pdfium.FPDF_InitLibraryWithConfig(config);
  }

  /// Loads a document from [path], and if necessary, a [password] can be
  /// specified.
  ///
  /// Throws an [PdfiumException] if no document is loaded.
  /// Returns a instance of [PdfiumWrap]
  PdfiumWrap loadDocumentFromPath(String path, {String? password}) {
    final filePathP = stringToNativeInt8(path);
    _document = pdfium.FPDF_LoadDocument(
      filePathP,
      password != null ? stringToNativeInt8(password) : nullptr,
    );
    if (_document == nullptr) {
      final err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }
    return this;
  }

  /// Loads a document from [bytes], and if necessary, a [password] can be
  /// specified.
  ///
  /// Throws an [PdfiumException] if the document is null.
  /// Returns a instance of [PdfiumWrap]
  PdfiumWrap loadDocumentFromBytes(Uint8List bytes, {String? password}) {
    // Allocate a pointer large enough.
    final frameData = allocator<Uint8>(bytes.length);
    // Create a list that uses our pointer and copy in the image data.
    final pointerList = frameData.asTypedList(bytes.length);
    pointerList.setAll(0, bytes);

    _document = pdfium.FPDF_LoadMemDocument64(
      frameData.cast<Void>(),
      bytes.length,
      password != null ? stringToNativeInt8(password) : nullptr,
    );

    if (_document == nullptr) {
      final err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }
    return this;
  }

  /// Loads a page from a document loaded
  ///
  /// Throws an [PdfiumException] if the no document is loaded, and a
  /// [PageException] if the page being attempted to load does not exist.
  /// Returns a instance of [PdfiumWrap]
  PdfiumWrap loadPage(int index) {
    if (_document == nullptr) {
      throw PdfiumException(message: 'Document not load');
    }
    _page = pdfium.FPDF_LoadPage(_document!, index);
    if (_page == nullptr) {
      final err = pdfium.getLastErrorMessage();
      throw PageException(message: err);
    }
    return this;
  }

  /// Returns the number of pages of the loaded document.
  ///
  /// Throws an [PdfiumException] if the no document is loaded
  int getPageCount() {
    if (_document == nullptr) {
      throw PdfiumException(message: 'Document not load');
    }
    return pdfium.FPDF_GetPageCount(_document!);
  }

  /// Returns the width of the loaded page.
  ///
  /// Throws an [PdfiumException] if no page is loaded
  double getPageWidth() {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    return pdfium.FPDF_GetPageWidth(_page!);
  }

  /// Returns the height of the loaded page.
  ///
  /// Throws an [PdfiumException] if no page is loaded
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
  Uint8List renderPageAsBytes(
    int width,
    int height, {
    int backgroundColor = 268435455,
    int rotate = 0,
    int flags = 0,
  }) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    final w = width;
    final h = height;
    const startX = 0;
    final sizeX = w;
    const startY = 0;
    final sizeY = h;

    // Create empty bitmap and render page onto it
    // The bitmap always uses 4 bytes per pixel. The first byte is always
    // double word aligned.
    // The byte order is BGRx (the last byte unused if no alpha channel) or
    // BGRA. flags FPDF_ANNOT | FPDF_LCD_TEXT

    bitmap = pdfium.FPDFBitmap_Create(w, h, 0);
    pdfium.FPDFBitmap_FillRect(bitmap!, 0, 0, w, h, backgroundColor);
    pdfium.FPDF_RenderPageBitmap(
      bitmap!,
      _page!,
      startX,
      startY,
      sizeX,
      sizeY,
      rotate,
      flags,
    );
    //  The pointer to the first byte of the bitmap buffer The data is in BGRA format
    buffer = pdfium.FPDFBitmap_GetBuffer(bitmap!);
    //stride = width * 4 bytes per pixel BGRA
    //var stride = pdfium.FPDFBitmap_GetStride(bitmap);
    //print('stride $stride');
    final list = buffer!.asTypedList(w * h * 4);

    return list;
  }

  /// Saves the loaded page as png image
  ///
  /// Throws an [PdfiumException] if no page is loaded.
  /// Returns a instance of [PdfiumWrap]
  PdfiumWrap savePageAsPng(
    String outPath, {
    int? width,
    int? height,
    int backgroundColor = 268435455,
    double scale = 1,
    int rotate = 0,
    int flags = 0,
    bool flush = false,
    int pngLevel = 6,
  }) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    final w = ((width ?? getPageWidth()) * scale).round();
    final h = ((height ?? getPageHeight()) * scale).round();

    final bytes = renderPageAsBytes(
      w,
      h,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
    );

    final Image image = Image.fromBytes(
      width: w,
      height: h,
      bytes: bytes.buffer,
      order: ChannelOrder.bgra,
      numChannels: 4,
    );

    // save bitmap as PNG.
    File(outPath)
        .writeAsBytesSync(encodePng(image, level: pngLevel), flush: flush);
    return this;
  }

  /// Saves the loaded page as jpg image
  ///
  /// Throws an [PdfiumException] if no page is loaded.
  /// Returns a instance of [PdfiumWrap]
  PdfiumWrap savePageAsJpg(
    String outPath, {
    int? width,
    int? height,
    int backgroundColor = 268435455,
    double scale = 1,
    int rotate = 0,
    int flags = 0,
    bool flush = false,
    int qualityJpg = 100,
  }) {
    if (_page == nullptr) {
      throw PdfiumException(message: 'Page not load');
    }
    // var backgroundStr = "FFFFFFFF"; // as int 268435455
    final w = ((width ?? getPageWidth()) * scale).round();
    final h = ((height ?? getPageHeight()) * scale).round();

    final bytes = renderPageAsBytes(
      w,
      h,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
    );

    final Image image = Image.fromBytes(
      width: w,
      height: h,
      bytes: bytes.buffer,
      order: ChannelOrder.bgra,
      numChannels: 4,
    );

    // save bitmap as PNG.
    File(outPath)
        .writeAsBytesSync(encodeJpg(image, quality: qualityJpg), flush: flush);
    return this;
  }

  /// Closes the page if it was open. Returns a instance of [PdfiumWrap]
  PdfiumWrap closePage() {
    if (_page != null && _page != nullptr) {
      pdfium.FPDF_ClosePage(_page!);

      if (bitmap != null && bitmap != nullptr) {
        pdfium.FPDFBitmap_Destroy(bitmap!);
      }
    }
    return this;
  }

  /// Closes the document if it was open. Returns a instance of [PdfiumWrap]
  PdfiumWrap closeDocument() {
    if (_document != null && _document != nullptr) {
      pdfium.FPDF_CloseDocument(_document!);
    }
    return this;
  }

  /// Destroys and releases the memory allocated for the library when is not
  /// longer used
  void dispose() {
    // closePage();
    // closeDocument();
    pdfium.FPDF_DestroyLibrary();
    allocator.free(config);
  }
}
