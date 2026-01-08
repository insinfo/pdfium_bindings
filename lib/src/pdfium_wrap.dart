//C:\MyDartProjects\pdfium\pdfium_bindings\lib\src\pdfium_wrap.dart
// ignore_for_file: camel_case_types, non_constant_identifier_names

import 'dart:async';
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

/// Describes a document to import when merging PDFs.
class PdfMergeSource {
  const PdfMergeSource({
    required this.documentPath,
    this.password,
    this.pageRange,
    this.pageIndices,
    this.insertIndex,
  }) : assert(
          pageRange == null || pageIndices == null,
          'Provide either pageRange or pageIndices, not both.',
        );

  /// Path to the source PDF.
  final String documentPath;

  /// Optional password for encrypted documents.
  final String? password;

  /// Range string (1-based, e.g. "1-3") to copy.
  final String? pageRange;

  /// Specific zero-based page indices to copy.
  final List<int>? pageIndices;

  /// Optional insert index for the destination document.
  final int? insertIndex;
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
  Pointer<FPDF_FORMFILLINFO>? formFillInfo;
  FPDF_FORMHANDLE? formHandle;

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
const int _kSaveFlagNoIncremental = 2;

final Map<int, RandomAccessFile> _fileWriterRegistry =
    <int, RandomAccessFile>{};

final Map<int, Timer> _formFillTimers = <int, Timer>{};
int _formFillTimerSeq = 1;

final Map<int, FPDF_PAGE> _formFillCurrentPageByDoc = <int, FPDF_PAGE>{};
final Map<int, int> _formFillCurrentPageIndexByDoc = <int, int>{};

void _formFillSetCurrentPageForDoc(
  FPDF_DOCUMENT document,
  FPDF_PAGE page,
  int pageIndex,
) {
  _formFillCurrentPageByDoc[document.address] = page;
  _formFillCurrentPageIndexByDoc[document.address] = pageIndex;
}

void _formFillClearCurrentPageForDoc(
  FPDF_DOCUMENT document,
  FPDF_PAGE page,
) {
  final current = _formFillCurrentPageByDoc[document.address];
  if (current != null && identical(current, page)) {
    _formFillCurrentPageByDoc.remove(document.address);
    _formFillCurrentPageIndexByDoc.remove(document.address);
  }
}

// PDFium's library lifecycle is process-global and can crash if
// `FPDF_DestroyLibrary()` races across isolates. To keep the wrapper stable
// (including when used from multiple isolates), we initialize PDFium once per
// isolate and never explicitly destroy the library.
//
// Note: The config pointer passed to `FPDF_InitLibraryWithConfig()` must remain
// valid until `FPDF_DestroyLibrary()`. Since we do not destroy the library, we
// intentionally keep this memory for the lifetime of the isolate.
bool _pdfiumLibraryInitialized = false;
final List<Pointer<Int8>> _pdfiumLibraryFontPathPointers = <Pointer<Int8>>[];

class _SyncFileMutex {
  _SyncFileMutex(String name)
      : _lockFile = File(path.join(Directory.systemTemp.path, name));

  final File _lockFile;

  T runExclusive<T>(T Function() action) {
    _lockFile.createSync(recursive: true);
    final handle = _lockFile.openSync(mode: FileMode.write);
    try {
      handle.lockSync(FileLock.blockingExclusive);
      try {
        return action();
      } finally {
        handle.unlockSync();
      }
    } finally {
      handle.closeSync();
    }
  }
}

final _SyncFileMutex _pdfiumLibraryInitMutex =
    _SyncFileMutex('pdfium_bindings_init.lock');

typedef WriteBlockNative = Int Function(
  Pointer<FPDF_FILEWRITE_>,
  Pointer<Void>,
  UnsignedLong,
);

int _fileWriteCallback(
  Pointer<FPDF_FILEWRITE_> fileWrite,
  Pointer<Void> data,
  int size,
) {
  final sink = _fileWriterRegistry[fileWrite.address];
  if (sink == null) {
    return 0;
  }
  try {
    final bytes = data.cast<Uint8>().asTypedList(size);
    sink.writeFromSync(bytes);
    return 1;
  } on Object {
    return 0;
  }
}

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
    //print('PdfiumWrap resolvedLibraryPath $resolvedLibraryPath | Platform.isLinux ${Platform.isLinux}');
    pdfium = PDFiumBindings(dylib);

    _cleanup = _CleanupState(pdfium: pdfium, allocator: allocator);
    _initializeLibrary();
    _finalizer.attach(this, _cleanup, detach: this);
  }

  /// Bindings to PDFium.
  late final PDFiumBindings pdfium;

  /// PDFium configuration pointer.
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
  FPDF_FORMHANDLE? _formHandle;
  bool _formFillPageAttached = false;

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
    if (_formHandle != null && _formHandle != nullptr) {
      _formFillSetCurrentPageForDoc(_document!, _page!, index);
      pdfium.FORM_OnAfterLoadPage(_page!, _formHandle!);
      _formFillPageAttached = true;
    }
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
    bool renderFormFields = false,
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
    final shouldRenderForms = renderFormFields ||
        (!_isPointerNull(_document) &&
            pdfium.FPDF_GetFormType(_document!) != 0);
    if (shouldRenderForms) {
      _ensureFormFill();
      if (_formHandle != null && _formHandle != nullptr) {
        if (!_formFillPageAttached) {
          if (!_isPointerNull(_document) && _currentPageIndex != null) {
            _formFillSetCurrentPageForDoc(
                _document!, _page!, _currentPageIndex!);
          }
          pdfium.FORM_OnAfterLoadPage(_page!, _formHandle!);
          _formFillPageAttached = true;
        }
        pdfium.FPDF_FFLDraw(
          _formHandle!,
          _bitmap!,
          _page!,
          startX,
          startY,
          width,
          height,
          rotate,
          flags,
        );
      }
    }

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
    bool renderFormFields = false,
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
      renderFormFields: renderFormFields,
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

  /// Reads the textual content of a page. When [pageIndex] is omitted the
  /// currently loaded page is used.
  String extractPageText({
    int? pageIndex,
    bool normalizeWhitespace = true,
  }) {
    _ensureNotDestroyed();
    if (_isPointerNull(_document)) {
      throw PdfiumException(message: 'Document not load');
    }

    Pointer<fpdf_page_t__>? targetPage;
    var closeTempPage = false;

    if (pageIndex == null) {
      if (_isPointerNull(_page)) {
        throw PdfiumException(message: 'Page not load');
      }
      targetPage = _page;
    } else if (!_isPointerNull(_page) && _currentPageIndex == pageIndex) {
      targetPage = _page;
    } else {
      final tempPage = pdfium.FPDF_LoadPage(_document!, pageIndex);
      if (_isPointerNull(tempPage)) {
        final err = pdfium.getLastErrorMessage();
        final reason = err.isEmpty
            ? 'Failed to load page index $pageIndex for text extraction'
            : err;
        throw PageException(message: reason);
      }
      targetPage = tempPage;
      closeTempPage = true;
    }

    final textPage = pdfium.FPDFText_LoadPage(targetPage!);
    if (_isPointerNull(textPage)) {
      if (closeTempPage) {
        pdfium.FPDF_ClosePage(targetPage);
      }
      throw PageException(message: 'Unable to load text page');
    }

    final charCount = pdfium.FPDFText_CountChars(textPage);
    if (charCount <= 0) {
      pdfium.FPDFText_ClosePage(textPage);
      if (closeTempPage) {
        pdfium.FPDF_ClosePage(targetPage);
      }
      return '';
    }

    final bufferLength = charCount + 1;
    final buffer = allocator<Uint16>(bufferLength);
    try {
      final copied = pdfium.FPDFText_GetText(
        textPage,
        0,
        charCount,
        buffer.cast<UnsignedShort>(),
      );
      if (copied <= 0) {
        return '';
      }
      final codeUnits = buffer.asTypedList(copied);
      final trimmedUnits = codeUnits.isNotEmpty && codeUnits.last == 0
          ? codeUnits.sublist(0, codeUnits.length - 1)
          : codeUnits;
      var text = String.fromCharCodes(trimmedUnits);
      if (normalizeWhitespace) {
        text = _normalizeExtractedText(text);
      }
      return text;
    } finally {
      pdfium.FPDFText_ClosePage(textPage);
      allocator.free(buffer);
      if (closeTempPage) {
        pdfium.FPDF_ClosePage(targetPage);
      }
    }
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

  /// Exports selected pages from [sourcePath] into a new PDF at [outputPath].
  static Future<void> extractPagesFromFile({
    required PdfiumConfig config,
    required String sourcePath,
    String? password,
    required String outputPath,
    List<int>? pageIndices,
    String? pageRange,
    bool copyViewerPreferences = true,
  }) {
    final sources = <PdfMergeSource>[
      PdfMergeSource(
        documentPath: sourcePath,
        password: password,
        pageIndices: pageIndices,
        pageRange: pageRange,
      ),
    ];
    return mergeDocuments(
      config: config,
      sources: sources,
      outputPath: outputPath,
      copyViewerPreferences: copyViewerPreferences,
    );
  }

  /// Merges multiple [PdfMergeSource] documents into a new file at [outputPath].
  static Future<void> mergeDocuments({
    required PdfiumConfig config,
    required List<PdfMergeSource> sources,
    required String outputPath,
    bool copyViewerPreferences = true,
  }) {
    return Future<void>.sync(() {
      if (sources.isEmpty) {
        throw ArgumentError.value(
            sources, 'sources', 'Provide at least one PDF');
      }

      final wrapper = PdfiumWrap(config: config);
      try {
        wrapper._mergeDocumentsInternal(
          sources: sources,
          outputPath: outputPath,
          copyViewerPreferences: copyViewerPreferences,
        );
      } finally {
        wrapper.dispose();
      }
    });
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
    _pdfiumLibraryInitMutex.runExclusive(() {
      if (_pdfiumLibraryInitialized) {
        return;
      }

      // Use a stable allocator for the global config memory.
      final configPointer = calloc<FPDF_LIBRARY_CONFIG>();
      configPointer.ref.version = _options.version;
      configPointer.ref.m_v8EmbedderSlot = _options.v8EmbedderSlot;
      configPointer.ref.m_pIsolate = _options.isolateAddress != null
          ? Pointer<Void>.fromAddress(_options.isolateAddress!)
          : nullptr;

      final fontPaths = List<String>.from(_options.userFontPaths);
      if (fontPaths.isNotEmpty) {
        final fontArray = calloc<Pointer<Int8>>(fontPaths.length + 1);
        for (var i = 0; i < fontPaths.length; i++) {
          final fontPtr = stringToNativeInt8(fontPaths[i], allocator: calloc);
          (fontArray + i).value = fontPtr;
          _pdfiumLibraryFontPathPointers.add(fontPtr);
        }
        (fontArray + fontPaths.length).value = nullptr;
        configPointer.ref.m_pUserFontPaths = fontArray.cast();
      } else {
        configPointer.ref.m_pUserFontPaths = nullptr;
      }

      pdfium.FPDF_InitLibraryWithConfig(configPointer);
      _pdfiumLibraryInitialized = true;
    });
  }

  void _closePageInternal() {
    if (_isPointerNull(_page)) {
      return;
    }
    if (_formHandle != null &&
        _formHandle != nullptr &&
        _formFillPageAttached) {
      pdfium.FORM_OnBeforeClosePage(_page!, _formHandle!);
      if (!_isPointerNull(_document)) {
        _formFillClearCurrentPageForDoc(_document!, _page!);
      }
      _formFillPageAttached = false;
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
    _destroyFormFill();
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
    // Only clean up per-instance resources. Do NOT call FPDF_DestroyLibrary():
    // it is process-global and can race across isolates.
    if (_cleanup.libraryDestroyed) {
      return;
    }

    if (_cleanup.bitmap != null && _cleanup.bitmap != nullptr) {
      pdfium.FPDFBitmap_Destroy(_cleanup.bitmap!);
    }

    if (_cleanup.document != null && _cleanup.document != nullptr) {
      if (_cleanup.formHandle != null && _cleanup.formHandle != nullptr) {
        pdfium.FPDFDOC_ExitFormFillEnvironment(_cleanup.formHandle!);
        _cleanup.formHandle = null;
      }
      pdfium.FPDF_CloseDocument(_cleanup.document!);
    }

    if (_cleanup.documentBytes != null) {
      _cleanup.allocator.free(_cleanup.documentBytes!);
      _cleanup.documentBytes = null;
    }

    if (_cleanup.formFillInfo != null) {
      _cleanup.allocator.free(_cleanup.formFillInfo!);
      _cleanup.formFillInfo = null;
    }

    _cleanup.libraryDestroyed = true;
  }

  static String _indicesToRangeString(List<int> indices) {
    if (indices.isEmpty) {
      return '';
    }
    final sorted = List<int>.from(indices)..sort();
    final buffer = StringBuffer();
    var start = sorted.first;
    var previous = start;

    void flush() {
      if (buffer.isNotEmpty) {
        buffer.write(',');
      }
      if (start == previous) {
        buffer.write(start + 1);
      } else {
        buffer.write('${start + 1}-${previous + 1}');
      }
    }

    for (var i = 1; i < sorted.length; i++) {
      final current = sorted[i];
      if (current == previous + 1) {
        previous = current;
        continue;
      }
      flush();
      start = previous = current;
    }

    flush();
    return buffer.toString();
  }

  static int _resolveDimension(
    int? explicitValue,
    double pageValue,
    double scale,
  ) {
    final value = explicitValue ?? (pageValue * scale).round();
    return value <= 0 ? 1 : value;
  }

  static String _normalizeExtractedText(String value) {
    if (value.isEmpty) {
      return value;
    }
    return value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  }

  void _mergeDocumentsInternal({
    required List<PdfMergeSource> sources,
    required String outputPath,
    required bool copyViewerPreferences,
  }) {
    final destDoc = pdfium.FPDF_CreateNewDocument();
    if (_isPointerNull(destDoc)) {
      throw PdfiumException(message: 'Failed to create destination document');
    }

    final openedDocs = <Pointer<fpdf_document_t__>>[];
    try {
      for (final source in sources) {
        final pathPtr =
            stringToNativeInt8(source.documentPath, allocator: allocator);
        Pointer<Int8>? passwordPtr;
        if (source.password != null) {
          passwordPtr =
              stringToNativeInt8(source.password!, allocator: allocator);
        }

        final doc = pdfium.FPDF_LoadDocument(
          pathPtr.cast(),
          passwordPtr != null ? passwordPtr.cast() : nullptr,
        );

        allocator.free(pathPtr);
        if (passwordPtr != null) {
          allocator.free(passwordPtr);
        }

        if (_isPointerNull(doc)) {
          final err = pdfium.FPDF_GetLastError();
          throw PdfiumException.fromErrorCode(err);
        }

        openedDocs.add(doc);

        final insertAt =
            source.insertIndex ?? pdfium.FPDF_GetPageCount(destDoc);
        var success = false;
        Pointer<Int8>? rangePtr;
        try {
          if (source.pageIndices != null && source.pageIndices!.isNotEmpty) {
            final rangeString = _indicesToRangeString(source.pageIndices!);
            rangePtr = stringToNativeInt8(rangeString, allocator: allocator);
            success = pdfium.FPDF_ImportPages(
                  destDoc,
                  doc,
                  rangePtr.cast(),
                  insertAt,
                ) !=
                0;
          } else {
            rangePtr = source.pageRange != null
                ? stringToNativeInt8(source.pageRange!, allocator: allocator)
                : null;
            success = pdfium.FPDF_ImportPages(
                  destDoc,
                  doc,
                  rangePtr != null ? rangePtr.cast() : nullptr,
                  insertAt,
                ) !=
                0;
          }
        } finally {
          if (rangePtr != null) {
            allocator.free(rangePtr);
          }
        }

        if (!success) {
          throw PageException(
            message: 'Failed to import pages from ${source.documentPath}',
          );
        }
      }

      if (copyViewerPreferences && openedDocs.isNotEmpty) {
        pdfium.FPDF_CopyViewerPreferences(destDoc, openedDocs.first);
      }

      _saveDocumentToPath(destDoc, outputPath);
    } finally {
      for (final doc in openedDocs) {
        pdfium.FPDF_CloseDocument(doc);
      }
    }
  }

  void _saveDocumentToPath(
    Pointer<fpdf_document_t__> document,
    String outputPath,
  ) {
    final writer = allocator<FPDF_FILEWRITE>();
    writer.ref
      ..version = 1
      ..WriteBlock = Pointer.fromFunction<WriteBlockNative>(
        _fileWriteCallback,
        0,
      );

    final file = File(outputPath);
    file.parent.createSync(recursive: true);
    final sink = file.openSync(mode: FileMode.write);
    _fileWriterRegistry[writer.address] = sink;

    final success = pdfium.FPDF_SaveAsCopy(
          document,
          writer,
          _kSaveFlagNoIncremental,
        ) !=
        0;

    pdfium.FPDF_CloseDocument(document);

    sink.closeSync();
    _fileWriterRegistry.remove(writer.address);
    allocator.free(writer);

    if (!success) {
      throw PdfiumException(message: 'Failed to save PDF to $outputPath');
    }
  }

  static String _resolveLibraryPath(String? overridePath) {
    if (overridePath != null) {
      return overridePath;
    }

    if (Platform.isMacOS) {
      return path.join(Directory.current.path, 'libpdfium.dylib');
    }
    if (Platform.isLinux) {
      return path.join(Directory.current.path, 'libpdfium.so');
    }
    if (Platform.isAndroid) {
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

void _formFillRelease(Pointer<FPDF_FORMFILLINFO> pThis) {}

void _formFillInvalidate(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
  double left,
  double top,
  double right,
  double bottom,
) {}

void _formFillOutputSelectedRect(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
  double left,
  double top,
  double right,
  double bottom,
) {}

void _formFillSetCursor(Pointer<FPDF_FORMFILLINFO> pThis, int nCursorType) {}

int _formFillSetTimer(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int uElapse,
  TimerCallback lpTimerFunc,
) {
  final id = _formFillTimerSeq++;
  final callback = lpTimerFunc.asFunction<DartTimerCallbackFunction>();
  _formFillTimers[id] = Timer(Duration(milliseconds: uElapse), () {
    try {
      callback(id);
    } finally {
      _formFillTimers.remove(id);
    }
  });
  return id;
}

void _formFillKillTimer(Pointer<FPDF_FORMFILLINFO> pThis, int nTimerID) {
  _formFillTimers.remove(nTimerID)?.cancel();
}

void _formFillOnChange(Pointer<FPDF_FORMFILLINFO> pThis) {}

FPDF_PAGE _formFillGetPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  int nPageIndex,
) {
  final curIdx = _formFillCurrentPageIndexByDoc[document.address];
  if (curIdx != null && curIdx == nPageIndex) {
    return _formFillCurrentPageByDoc[document.address] ?? nullptr;
  }
  return nullptr;
}

FPDF_PAGE _formFillGetCurrentPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
) {
  return _formFillCurrentPageByDoc[document.address] ?? nullptr;
}

int _formFillGetRotation(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
) {
  return 0;
}

void _formFillExecuteNamedAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_BYTESTRING namedAction,
) {}

void _formFillSetTextFieldFocus(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_WIDESTRING value,
  int valueLen,
  int isFocus,
) {}

void _formFillDoUriAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_BYTESTRING bsURI,
) {}

void _formFillDoGoToAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int nPageIndex,
  int zoomMode,
  Pointer<Float> fPosArray,
  int sizeofArray,
) {}

int _formFillGetCurrentPageIndex(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
) {
  return _formFillCurrentPageIndexByDoc[document.address] ?? 0;
}

void _formFillSetCurrentPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  int iCurPage,
) {}

void _formFillGotoUrl(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  FPDF_WIDESTRING wsURL,
) {}

void _formFillGetPageViewRect(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
  Pointer<Double> left,
  Pointer<Double> top,
  Pointer<Double> right,
  Pointer<Double> bottom,
) {}

void _formFillPageEvent(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int pageCount,
  int eventType,
) {}

int _formFillPopupMenu(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
  FPDF_WIDGET hWidget,
  int menuFlag,
  double x,
  double y,
) {
  return 0;
}

Pointer<FPDF_FILEHANDLER> _formFillOpenFile(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int fileFlag,
  FPDF_WIDESTRING wsURL,
  Pointer<Char> mode,
) {
  return nullptr;
}

void _formFillEmailTo(
  Pointer<FPDF_FORMFILLINFO> pThis,
  Pointer<FPDF_FILEHANDLER> fileHandler,
  FPDF_WIDESTRING pTo,
  FPDF_WIDESTRING pSubject,
  FPDF_WIDESTRING pCC,
  FPDF_WIDESTRING pBcc,
  FPDF_WIDESTRING pMsg,
) {}

void _formFillUploadTo(
  Pointer<FPDF_FORMFILLINFO> pThis,
  Pointer<FPDF_FILEHANDLER> fileHandler,
  int fileFlag,
  FPDF_WIDESTRING uploadTo,
) {}

int _formFillGetPlatform(
  Pointer<FPDF_FORMFILLINFO> pThis,
  Pointer<Void> platform,
  int length,
) {
  return 0;
}

int _formFillGetLanguage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  Pointer<Void> language,
  int length,
) {
  return 0;
}

Pointer<FPDF_FILEHANDLER> _formFillDownloadFromUrl(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_WIDESTRING url,
) {
  return nullptr;
}

int _formFillPostRequestUrl(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_WIDESTRING wsURL,
  FPDF_WIDESTRING wsData,
  FPDF_WIDESTRING wsContentType,
  FPDF_WIDESTRING wsEncode,
  FPDF_WIDESTRING wsHeader,
  Pointer<FPDF_BSTR> response,
) {
  return 0;
}

int _formFillPutRequestUrl(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_WIDESTRING wsURL,
  FPDF_WIDESTRING wsData,
  FPDF_WIDESTRING wsEncode,
) {
  return 0;
}

void _formFillOnFocusChange(
  Pointer<FPDF_FORMFILLINFO> param,
  FPDF_ANNOTATION annot,
  int pageIndex,
) {}

void _formFillDoUriActionWithKeyboardModifier(
  Pointer<FPDF_FORMFILLINFO> param,
  FPDF_BYTESTRING uri,
  int modifiers,
) {}

extension _PdfiumFormFill on PdfiumWrap {
  void _ensureFormFill() {
    if (_formHandle != null && _formHandle != nullptr) {
      return;
    }
    if (PdfiumWrap._isPointerNull(_document)) {
      return;
    }

    final info = allocator<FPDF_FORMFILLINFO>();
    info.ref.version = 1;
    info.ref.xfa_disabled = 1;

    info.ref.Release =
        Pointer.fromFunction<Void Function(Pointer<FPDF_FORMFILLINFO>)>(
      _formFillRelease,
    );
    info.ref.FFI_Invalidate = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, Double, Double,
            Double, Double)>(_formFillInvalidate);
    info.ref.FFI_OutputSelectedRect = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, Double, Double,
            Double, Double)>(_formFillOutputSelectedRect);
    info.ref.FFI_SetCursor =
        Pointer.fromFunction<Void Function(Pointer<FPDF_FORMFILLINFO>, Int)>(
            _formFillSetCursor);
    info.ref.FFI_SetTimer = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, Int, TimerCallback)>(
      _formFillSetTimer,
      0,
    );
    info.ref.FFI_KillTimer =
        Pointer.fromFunction<Void Function(Pointer<FPDF_FORMFILLINFO>, Int)>(
            _formFillKillTimer);
    // Dart FFI can't safely provide callbacks that return structs by value.
    // PDFium usually doesn't need this for headless rendering; keep it null.
    info.ref.FFI_GetLocalTime = nullptr;
    info.ref.FFI_OnChange =
        Pointer.fromFunction<Void Function(Pointer<FPDF_FORMFILLINFO>)>(
            _formFillOnChange);
    info.ref.FFI_GetPage = Pointer.fromFunction<
        FPDF_PAGE Function(
            Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, Int)>(_formFillGetPage);
    info.ref.FFI_GetCurrentPage = Pointer.fromFunction<
        FPDF_PAGE Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT)>(
      _formFillGetCurrentPage,
    );
    info.ref.FFI_GetRotation = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE)>(
      _formFillGetRotation,
      0,
    );
    info.ref.FFI_ExecuteNamedAction = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_BYTESTRING)>(
      _formFillExecuteNamedAction,
    );
    info.ref.FFI_SetTextFieldFocus = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_WIDESTRING, FPDF_DWORD,
            FPDF_BOOL)>(
      _formFillSetTextFieldFocus,
    );
    info.ref.FFI_DoURIAction = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_BYTESTRING)>(
      _formFillDoUriAction,
    );
    info.ref.FFI_DoGoToAction = Pointer.fromFunction<
        Void Function(
            Pointer<FPDF_FORMFILLINFO>, Int, Int, Pointer<Float>, Int)>(
      _formFillDoGoToAction,
    );
    info.ref.FFI_GetCurrentPageIndex = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT)>(
      _formFillGetCurrentPageIndex,
      0,
    );
    info.ref.FFI_SetCurrentPage = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, Int)>(
      _formFillSetCurrentPage,
    );
    info.ref.FFI_GotoURL = Pointer.fromFunction<
        Void Function(
            Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, FPDF_WIDESTRING)>(
      _formFillGotoUrl,
    );
    info.ref.FFI_GetPageViewRect = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, Pointer<Double>,
            Pointer<Double>, Pointer<Double>, Pointer<Double>)>(
      _formFillGetPageViewRect,
    );
    info.ref.FFI_PageEvent = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, Int, FPDF_DWORD)>(
      _formFillPageEvent,
    );
    info.ref.FFI_PopupMenu = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, FPDF_WIDGET, Int,
            Float, Float)>(
      _formFillPopupMenu,
      0,
    );
    info.ref.FFI_OpenFile = Pointer.fromFunction<
        Pointer<FPDF_FILEHANDLER> Function(
            Pointer<FPDF_FORMFILLINFO>, Int, FPDF_WIDESTRING, Pointer<Char>)>(
      _formFillOpenFile,
    );
    info.ref.FFI_EmailTo = Pointer.fromFunction<
        Void Function(
            Pointer<FPDF_FORMFILLINFO>,
            Pointer<FPDF_FILEHANDLER>,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING)>(_formFillEmailTo);
    info.ref.FFI_UploadTo = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, Pointer<FPDF_FILEHANDLER>,
            Int, FPDF_WIDESTRING)>(_formFillUploadTo);
    info.ref.FFI_GetPlatform = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, Pointer<Void>, Int)>(
      _formFillGetPlatform,
      0,
    );
    info.ref.FFI_GetLanguage = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, Pointer<Void>, Int)>(
      _formFillGetLanguage,
      0,
    );
    info.ref.FFI_DownloadFromURL = Pointer.fromFunction<
        Pointer<FPDF_FILEHANDLER> Function(
            Pointer<FPDF_FORMFILLINFO>, FPDF_WIDESTRING)>(
      _formFillDownloadFromUrl,
    );
    info.ref.FFI_PostRequestURL = Pointer.fromFunction<
        Int Function(
            Pointer<FPDF_FORMFILLINFO>,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            FPDF_WIDESTRING,
            Pointer<FPDF_BSTR>)>(
      _formFillPostRequestUrl,
      0,
    );
    info.ref.FFI_PutRequestURL = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_WIDESTRING,
            FPDF_WIDESTRING, FPDF_WIDESTRING)>(
      _formFillPutRequestUrl,
      0,
    );
    info.ref.FFI_OnFocusChange = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_ANNOTATION, Int)>(
      _formFillOnFocusChange,
    );
    info.ref.FFI_DoURIActionWithKeyboardModifier = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_BYTESTRING, Int)>(
      _formFillDoUriActionWithKeyboardModifier,
    );

    final handle = pdfium.FPDFDOC_InitFormFillEnvironment(_document!, info);
    _formHandle = handle;
    _cleanup.formHandle = handle;
    _cleanup.formFillInfo = info;

    if (_formHandle != null && _formHandle != nullptr) {
      pdfium.FPDF_SetFormFieldHighlightAlpha(_formHandle!, 0);
      pdfium.FORM_DoDocumentJSAction(_formHandle!);
      pdfium.FORM_DoDocumentOpenAction(_formHandle!);
    }
  }

  void _destroyFormFill() {
    if (_formHandle != null && _formHandle != nullptr) {
      pdfium.FPDFDOC_ExitFormFillEnvironment(_formHandle!);
      _formHandle = null;
      _cleanup.formHandle = null;
    }
    if (_cleanup.formFillInfo != null) {
      allocator.free(_cleanup.formFillInfo!);
      _cleanup.formFillInfo = null;
    }
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

    // Intentionally do NOT call FPDF_DestroyLibrary() from a finalizer.
    // It is process-global and can crash if another isolate is still using it.
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
