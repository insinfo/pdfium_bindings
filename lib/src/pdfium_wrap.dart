//C:\MyDartProjects\pdfium\pdfium_bindings\lib\src\pdfium_wrap.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/src/exceptions.dart';
import 'package:pdfium_bindings/src/extensions.dart';
import 'package:pdfium_bindings/src/pdfium_bindings.dart';
import 'package:pdfium_bindings/src/utils.dart';

/// Immutable configuration for initializing the PDFium library.
class PdfiumConfig {
  const PdfiumConfig({
    this.libraryPath,
    this.version = 2,
    this.userFontPaths = const [],
    this.isolateAddress,
    this.v8EmbedderSlot = 0,
  });

  /// Optional explicit path to the native pdfium library.
  final String? libraryPath;

  /// Version to pass to `FPDF_LIBRARY_CONFIG.version`.
  final int version;

  /// Optional font directories supplied to `m_pUserFontPaths`.
  final List<String> userFontPaths;

  /// Optional pointer address for V8 isolate integration.
  final int? isolateAddress;

  /// Value for `m_v8EmbedderSlot`.
  final int v8EmbedderSlot;

  /// Returns a copy with selectively overridden values.
  PdfiumConfig copyWith({
    String? libraryPath,
    int? version,
    List<String>? userFontPaths,
    int? isolateAddress,
    int? v8EmbedderSlot,
  }) {
    return PdfiumConfig(
      libraryPath: libraryPath ?? this.libraryPath,
      version: version ?? this.version,
      userFontPaths: userFontPaths ?? this.userFontPaths,
      isolateAddress: isolateAddress ?? this.isolateAddress,
      v8EmbedderSlot: v8EmbedderSlot ?? this.v8EmbedderSlot,
    );
  }
}

class _CleanupState {
  _CleanupState({required this.pdfium, required this.allocator});

  final PDFiumBindings pdfium;
  final Allocator allocator;

  Pointer<FPDF_LIBRARY_CONFIG>? config;
  Pointer<Pointer<Int8>>? fontPathArray;
  final List<Pointer<Int8>> fontPathPointers = <Pointer<Int8>>[];

  Pointer<fpdf_document_t__>? document;
  Pointer<fpdf_page_t__>? page;
  Pointer<fpdf_bitmap_t__>? bitmap;
  Pointer<Uint8>? documentBytes;

  bool libraryDestroyed = false;
  bool disposed = false;
}

class _AsyncImageResult {
  _AsyncImageResult(this.width, this.height, this.bytes);

  final int width;
  final int height;
  final TransferableTypedData bytes;
}

const int _kDefaultBackgroundColor = 0x0FFFFFFF;

/// Wrapper class to abstract the PDFium logic.
class PdfiumWrap {
  PdfiumWrap({
    String? libraryPath,
    PdfiumConfig config = const PdfiumConfig(),
    this.allocator = calloc,
  }) : _options = libraryPath != null
            ? config.copyWith(libraryPath: libraryPath)
            : config {
    final resolvedLibraryPath = _resolveLibraryPath(_options.libraryPath);
    if (!Platform.isIOS && !File(resolvedLibraryPath).existsSync()) {
      throw MissingLibraryException(path: resolvedLibraryPath);
    }

    final DynamicLibrary dylib = Platform.isIOS
        ? DynamicLibrary.process()
        : DynamicLibrary.open(resolvedLibraryPath);
    pdfium = PDFiumBindings(dylib);

    _cleanup = _CleanupState(pdfium: pdfium, allocator: allocator);
    _initializeLibrary();
    _finalizer.attach(this, _cleanup, detach: this);
  }

  /// Bindings to PDFium.
  late final PDFiumBindings pdfium;

  /// PDFium configuration pointer.
  Pointer<FPDF_LIBRARY_CONFIG>? _configPointer;
  final Allocator allocator;
  final PdfiumConfig _options;

  late final _CleanupState _cleanup;
  bool _destroyed = false;

  Pointer<fpdf_document_t__>? _document;
  Pointer<fpdf_page_t__>? _page;
  Pointer<fpdf_bitmap_t__>? _bitmap;
  Pointer<Uint8>? _buffer;
  Pointer<Uint8>? _documentBytes;
  int? _currentPageIndex;

  /// True when a document is currently loaded.
  bool get hasOpenDocument => !_isPointerNull(_document);

  /// True when a page is currently loaded.
  bool get hasOpenPage => !_isPointerNull(_page);

  /// True when `dispose` has already been called or the wrapper was finalized.
  bool get isDisposed => _destroyed;

  /// Loads a document from [path]. Optionally accepts a [password].
  ///
  /// Throws a [PdfiumException] if the document cannot be opened.
  PdfiumWrap loadDocumentFromPath(String path, {String? password}) {
    _ensureNotDestroyed();
    _closeDocumentInternal();

    final filePathP = stringToNativeInt8(path, allocator: allocator);
    Pointer<Int8>? passwordP;
    if (password != null) {
      passwordP = stringToNativeInt8(password, allocator: allocator);
    }

    final doc = pdfium.FPDF_LoadDocument(
      filePathP.cast<Char>(),
      passwordP != null ? passwordP.cast<Char>() : nullptr,
    );

    allocator.free(filePathP);
    if (passwordP != null) {
      allocator.free(passwordP);
    }

    if (_isPointerNull(doc)) {
      final err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }

    _document = doc;
    _cleanup.document = doc;
    return this;
  }

  /// Loads a document from in-memory [bytes], optionally using a [password].
  PdfiumWrap loadDocumentFromBytes(Uint8List bytes, {String? password}) {
    _ensureNotDestroyed();
    _closeDocumentInternal();

    final frameData = allocator<Uint8>(bytes.length);
    frameData.asTypedList(bytes.length).setAll(0, bytes);
    _documentBytes = frameData;
    _cleanup.documentBytes = frameData;

    Pointer<Int8>? passwordP;
    if (password != null) {
      passwordP = stringToNativeInt8(password, allocator: allocator);
    }

    final doc = pdfium.FPDF_LoadMemDocument64(
      frameData.cast<Void>(),
      bytes.length,
      passwordP != null ? passwordP.cast<Char>() : nullptr,
    );

    if (passwordP != null) {
      allocator.free(passwordP);
    }

    if (_isPointerNull(doc)) {
      allocator.free(frameData);
      _cleanup.documentBytes = null;
      _documentBytes = null;
      final err = pdfium.FPDF_GetLastError();
      throw PdfiumException.fromErrorCode(err);
    }

    _document = doc;
    _cleanup.document = doc;
    return this;
  }

  /// Loads the page at [index].
  PdfiumWrap loadPage(int index) {
    _ensureNotDestroyed();
    if (_isPointerNull(_document)) {
      throw PdfiumException(message: 'Document not load');
    }

    _closePageInternal();
    final page = pdfium.FPDF_LoadPage(_document!, index);
    if (_isPointerNull(page)) {
      final err = pdfium.getLastErrorMessage();
      throw PageException(message: err);
    }

    _page = page;
    _cleanup.page = page;
    _currentPageIndex = index;
    return this;
  }

  /// Returns the number of pages in the loaded document.
  int getPageCount() {
    _ensureNotDestroyed();
    if (_isPointerNull(_document)) {
      throw PdfiumException(message: 'Document not load');
    }
    return pdfium.FPDF_GetPageCount(_document!);
  }

  /// Returns the width of the currently loaded page.
  double getPageWidth() {
    _ensureNotDestroyed();
    if (_isPointerNull(_page)) {
      throw PdfiumException(message: 'Page not load');
    }
    return pdfium.FPDF_GetPageWidth(_page!);
  }

  /// Returns the height of the currently loaded page.
  double getPageHeight() {
    _ensureNotDestroyed();
    if (_isPointerNull(_page)) {
      throw PdfiumException(message: 'Page not load');
    }
    return pdfium.FPDF_GetPageHeight(_page!);
  }

  /// Renders the current page into a BGRA byte buffer.
  Uint8List renderPageAsBytes(
    int width,
    int height, {
    int backgroundColor = _kDefaultBackgroundColor,
    int rotate = 0,
    int flags = 0,
    int startX = 0,
    int startY = 0,
  }) {
    _ensureNotDestroyed();
    if (_isPointerNull(_page)) {
      throw PdfiumException(message: 'Page not load');
    }

    _destroyExistingBitmap();

    _bitmap = pdfium.FPDFBitmap_Create(width, height, 0);
    _cleanup.bitmap = _bitmap;
    if (_isPointerNull(_bitmap)) {
    const message = 'Unable to create bitmap';
      _logRenderFailure(message, width, height, flags, rotate);
      throw PageRenderException(
        message: message,
        pageIndex: _currentPageIndex,
        width: width,
        height: height,
        flags: flags,
        rotate: rotate,
        errorDetails: 'FPDFBitmap_Create returned nullptr',
      );
    }

    pdfium.FPDFBitmap_FillRect(_bitmap!, 0, 0, width, height, backgroundColor);
    pdfium.FPDF_RenderPageBitmap(
      _bitmap!,
      _page!,
      startX,
      startY,
      width,
      height,
      rotate,
      flags,
    );

    final rawBuffer = pdfium.FPDFBitmap_GetBuffer(_bitmap!);
    if (rawBuffer == nullptr) {
    const message = 'Unable to obtain bitmap buffer';
      _logRenderFailure(message, width, height, flags, rotate);
      throw PageRenderException(
        message: message,
        pageIndex: _currentPageIndex,
        width: width,
        height: height,
        flags: flags,
        rotate: rotate,
        errorDetails: 'FPDFBitmap_GetBuffer returned nullptr',
      );
    }

    _buffer = rawBuffer.cast<Uint8>();
    final list = _buffer!.asTypedList(width * height * 4);
    return list;
  }

  /// Renders the current page to an [Image].
  Image renderPageToImage({
    int? width,
    int? height,
    double scale = 1,
    int backgroundColor = _kDefaultBackgroundColor,
    int rotate = 0,
    int flags = 0,
    int startX = 0,
    int startY = 0,
  }) {
    _ensureNotDestroyed();
    if (_isPointerNull(_page)) {
      throw PdfiumException(message: 'Page not load');
    }

    final resolvedWidth = _resolveDimension(width, getPageWidth(), scale);
    final resolvedHeight = _resolveDimension(height, getPageHeight(), scale);

    final bytes = renderPageAsBytes(
      resolvedWidth,
      resolvedHeight,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
      startX: startX,
      startY: startY,
    );

    return Image.fromBytes(
      width: resolvedWidth,
      height: resolvedHeight,
      bytes: bytes.buffer,
      order: ChannelOrder.bgra,
      numChannels: 4,
    );
  }

  /// Renders a cropped region of the current page.
  Uint8List renderRegion({
    required int startX,
    required int startY,
    required int width,
    required int height,
    int backgroundColor = _kDefaultBackgroundColor,
    int rotate = 0,
    int flags = 0,
  }) {
    return renderPageAsBytes(
      width,
      height,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
      startX: startX,
      startY: startY,
    );
  }

  /// Asynchronously renders a page in an isolate and returns it as an [Image].
  static Future<Image> renderPageToImageAsync({
    required PdfiumConfig config,
    required String documentPath,
    int pageIndex = 0,
    String? password,
    int? width,
    int? height,
    double scale = 1,
    int backgroundColor = _kDefaultBackgroundColor,
    int rotate = 0,
    int flags = 0,
    int startX = 0,
    int startY = 0,
  }) async {
    if (config.isolateAddress != null) {
      throw ArgumentError(
        'renderPageToImageAsync does not support isolateAddress overrides.',
      );
    }

    final result = await Isolate.run(() {
      final wrapper = PdfiumWrap(config: config);
      try {
        wrapper.loadDocumentFromPath(documentPath, password: password);
        wrapper.loadPage(pageIndex);
        final resolvedWidth = _resolveDimension(
          width,
          wrapper.getPageWidth(),
          scale,
        );
        final resolvedHeight = _resolveDimension(
          height,
          wrapper.getPageHeight(),
          scale,
        );
        final bytes = wrapper.renderPageAsBytes(
          resolvedWidth,
          resolvedHeight,
          backgroundColor: backgroundColor,
          rotate: rotate,
          flags: flags,
          startX: startX,
          startY: startY,
        );
        final copy = Uint8List.fromList(bytes);
        return _AsyncImageResult(
          resolvedWidth,
          resolvedHeight,
          TransferableTypedData.fromList(<Uint8List>[copy]),
        );
      } finally {
        wrapper.dispose();
      }
    });

    final data = result.bytes.materialize().asUint8List();
    return Image.fromBytes(
      width: result.width,
      height: result.height,
      bytes: data.buffer,
      order: ChannelOrder.bgra,
    );
  }

  /// Saves the loaded page as PNG image.
  PdfiumWrap savePageAsPng(
    String outPath, {
    int? width,
    int? height,
    int backgroundColor = _kDefaultBackgroundColor,
    double scale = 1,
    int rotate = 0,
    int flags = 0,
    bool flush = false,
    int pngLevel = 6,
  }) {
    final image = renderPageToImage(
      width: width,
      height: height,
      scale: scale,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
    );
    File(outPath)
        .writeAsBytesSync(encodePng(image, level: pngLevel), flush: flush);
    return this;
  }

  /// Saves the loaded page as JPEG image.
  PdfiumWrap savePageAsJpg(
    String outPath, {
    int? width,
    int? height,
    int backgroundColor = _kDefaultBackgroundColor,
    double scale = 1,
    int rotate = 0,
    int flags = 0,
    bool flush = false,
    int qualityJpg = 100,
  }) {
    final image = renderPageToImage(
      width: width,
      height: height,
      scale: scale,
      backgroundColor: backgroundColor,
      rotate: rotate,
      flags: flags,
    );
    File(outPath)
        .writeAsBytesSync(encodeJpg(image, quality: qualityJpg), flush: flush);
    return this;
  }

  /// Closes the currently loaded page.
  PdfiumWrap closePage() {
    _ensureNotDestroyed();
    _closePageInternal();
    return this;
  }

  /// Closes the currently loaded document.
  PdfiumWrap closeDocument() {
    _ensureNotDestroyed();
    _closeDocumentInternal();
    return this;
  }

  /// Releases native resources. Safe to call multiple times.
  void dispose() {
    if (_destroyed) {
      return;
    }
    _finalizer.detach(this);
    _disposeInternal();
  }

  void _disposeInternal({bool fromFinalizer = false}) {
    if (_destroyed) {
      return;
    }
    try {
      _closeDocumentInternal();
      _destroyLibraryInternal();
    } catch (error) {
      if (fromFinalizer) {
        stderr.writeln('PdfiumWrap finalizer failed: $error');
        return;
      }
      rethrow;
    } finally {
      _destroyed = true;
      _cleanup.disposed = true;
    }
  }

  void _ensureNotDestroyed() {
    if (_destroyed) {
      throw StateError('PdfiumWrap has been disposed.');
    }
  }

  void _initializeLibrary() {
    _configPointer = allocator<FPDF_LIBRARY_CONFIG>();
    _configPointer!.ref.version = _options.version;
    _configPointer!.ref.m_v8EmbedderSlot = _options.v8EmbedderSlot;
    _configPointer!.ref.m_pIsolate = _options.isolateAddress != null
        ? Pointer<Void>.fromAddress(_options.isolateAddress!)
        : nullptr;

    final fontPaths = List<String>.from(_options.userFontPaths);
    if (fontPaths.isNotEmpty) {
      final fontArray = allocator<Pointer<Int8>>(fontPaths.length + 1);
      _cleanup.fontPathArray = fontArray;
      for (var i = 0; i < fontPaths.length; i++) {
        final fontPtr = stringToNativeInt8(
          fontPaths[i],
          allocator: allocator,
        );
        (fontArray + i).value = fontPtr;
        _cleanup.fontPathPointers.add(fontPtr);
      }
      (fontArray + fontPaths.length).value = nullptr;
      _configPointer!.ref.m_pUserFontPaths = fontArray.cast();
    } else {
      _configPointer!.ref.m_pUserFontPaths = nullptr;
    }

    _cleanup.config = _configPointer;
    pdfium.FPDF_InitLibraryWithConfig(_configPointer!);
  }

  void _closePageInternal() {
    if (_isPointerNull(_page)) {
      return;
    }
    pdfium.FPDF_ClosePage(_page!);
    _cleanup.page = null;
    _page = null;

    _destroyExistingBitmap();
    _currentPageIndex = null;
  }

  void _closeDocumentInternal() {
    _closePageInternal();
    if (_isPointerNull(_document)) {
      return;
    }
    pdfium.FPDF_CloseDocument(_document!);
    _cleanup.document = null;
    _document = null;

    if (_documentBytes != null) {
      allocator.free(_documentBytes!);
      _documentBytes = null;
      _cleanup.documentBytes = null;
    }
  }

  void _destroyExistingBitmap() {
    if (_isPointerNull(_bitmap)) {
      return;
    }
    pdfium.FPDFBitmap_Destroy(_bitmap!);
    _cleanup.bitmap = null;
    _bitmap = null;
    _buffer = null;
  }

  void _destroyLibraryInternal() {
    if (_cleanup.libraryDestroyed) {
      return;
    }

    if (_cleanup.bitmap != null && _cleanup.bitmap != nullptr) {
      pdfium.FPDFBitmap_Destroy(_cleanup.bitmap!);
    }

    if (_cleanup.document != null && _cleanup.document != nullptr) {
      pdfium.FPDF_CloseDocument(_cleanup.document!);
    }

    if (_cleanup.documentBytes != null) {
      _cleanup.allocator.free(_cleanup.documentBytes!);
      _cleanup.documentBytes = null;
    }

    for (final fontPtr in _cleanup.fontPathPointers) {
      _cleanup.allocator.free(fontPtr);
    }
    _cleanup.fontPathPointers.clear();

    if (_cleanup.fontPathArray != null) {
      _cleanup.allocator.free(_cleanup.fontPathArray!);
      _cleanup.fontPathArray = null;
    }

    if (_cleanup.config != null) {
      pdfium.FPDF_DestroyLibrary();
      _cleanup.allocator.free(_cleanup.config!);
      _cleanup.config = null;
    } else {
      pdfium.FPDF_DestroyLibrary();
    }

    _cleanup.libraryDestroyed = true;
  }

  static int _resolveDimension(
    int? explicitValue,
    double pageValue,
    double scale,
  ) {
    final value = explicitValue ?? (pageValue * scale).round();
    return value <= 0 ? 1 : value;
  }

  static String _resolveLibraryPath(String? overridePath) {
    if (overridePath != null) {
      return overridePath;
    }

    if (Platform.isMacOS) {
      return path.join(Directory.current.path, 'libpdfium.dylib');
    }
    if (Platform.isLinux || Platform.isAndroid) {
      return path.join(Directory.current.path, 'libpdfium.so');
    }
    return path.join(Directory.current.path, 'pdfium.dll');
  }

  static void _logRenderFailure(
    String message,
    int width,
    int height,
    int flags,
    int rotate,
  ) {
    stderr.writeln(
      'PdfiumWrap: $message | size=${width}x$height | flags=$flags | rotate=$rotate',
    );
  }

  static bool _isPointerNull<T extends NativeType>(Pointer<T>? pointer) {
    return pointer == null || pointer == nullptr;
  }
}

void _disposeCleanupState(_CleanupState state, {bool fromFinalizer = false}) {
  if (state.disposed) {
    return;
  }
  final allocator = state.allocator;
  try {
    if (state.bitmap != null && state.bitmap != nullptr) {
      state.pdfium.FPDFBitmap_Destroy(state.bitmap!);
    }

    if (state.page != null && state.page != nullptr) {
      state.pdfium.FPDF_ClosePage(state.page!);
    }

    if (state.document != null && state.document != nullptr) {
      state.pdfium.FPDF_CloseDocument(state.document!);
    }

    if (state.documentBytes != null) {
      allocator.free(state.documentBytes!);
      state.documentBytes = null;
    }

    for (final fontPtr in state.fontPathPointers) {
      allocator.free(fontPtr);
    }
    state.fontPathPointers.clear();

    if (state.fontPathArray != null) {
      allocator.free(state.fontPathArray!);
      state.fontPathArray = null;
    }

    if (state.config != null) {
      state.pdfium.FPDF_DestroyLibrary();
      allocator.free(state.config!);
      state.config = null;
    } else if (!state.libraryDestroyed) {
      state.pdfium.FPDF_DestroyLibrary();
    }
  } catch (error, stackTrace) {
    if (!fromFinalizer) {
      rethrow;
    }
    stderr.writeln('PdfiumWrap finalizer failed: $error\n$stackTrace');
  } finally {
    state.disposed = true;
    state.libraryDestroyed = true;
  }
}

final Finalizer<_CleanupState> _finalizer = Finalizer<_CleanupState>(
  (state) => _disposeCleanupState(state, fromFinalizer: true),
);
