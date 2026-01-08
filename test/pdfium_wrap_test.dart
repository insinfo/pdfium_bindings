import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:test/test.dart';

typedef _PdfRect = ({double left, double bottom, double right, double top});

void main() {
  final libraryPath = _resolveLibraryPath();
  final pdfPath = p.join(Directory.current.path, '1417.pdf');
  final pdfExists = File(pdfPath).existsSync();
  final govbrPath = p.join(
    Directory.current.path,
    'test',
    'assets',
    'sample_govbr_signature_assinado.pdf',
  );
  final govbrExists = File(govbrPath).existsSync();

  final ass3Path = p.join(
    Directory.current.path,
    'test',
    'assets',
    '3_ass.pdf',
  );
  final ass3Exists = File(ass3Path).existsSync();

  final jornalPath = p.join(
    Directory.current.path,
    'test',
    'assets',
    'jornal.pdf',
  );
  final jornalExists = File(jornalPath).existsSync();
  final skipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !pdfExists
          ? 'sample PDF not found at $pdfPath'
          : null;
  final govbrSkipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !govbrExists
          ? 'govbr sample PDF not found at $govbrPath'
          : null;

    final ass3SkipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !ass3Exists
        ? 'sample PDF not found at $ass3Path'
        : null;

  final jornalSkipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !jornalExists
          ? 'sample PDF not found at $jornalPath'
          : null;

  group('PdfiumWrap', () {
    late PdfiumWrap wrapper;
    late PdfiumConfig config;

    setUp(() {
      if (skipReason != null) {
        return;
      }
      config = PdfiumConfig(libraryPath: libraryPath, v8EmbedderSlot: 7);
      wrapper = PdfiumWrap(config: config);
    });

    tearDown(() {
      if (skipReason != null) {
        return;
      }
      wrapper.dispose();
    });

    test('getPageCount throws when document not loaded', () {
      expect(() => wrapper.getPageCount(), throwsA(isA<PdfiumException>()));
    }, skip: skipReason);

    test('hasOpenDocument and hasOpenPage reflect state transitions', () {
      expect(wrapper.hasOpenDocument, isFalse);
      expect(wrapper.hasOpenPage, isFalse);

      wrapper.loadDocumentFromPath(pdfPath);
      expect(wrapper.hasOpenDocument, isTrue);
      expect(wrapper.hasOpenPage, isFalse);

      wrapper.loadPage(0);
      expect(wrapper.hasOpenPage, isTrue);

      wrapper.closePage();
      expect(wrapper.hasOpenPage, isFalse);

      wrapper.closeDocument();
      expect(wrapper.hasOpenDocument, isFalse);
    }, skip: skipReason);

    test('renderPageAsBytes returns BGRA buffer for first page', () {
      wrapper.loadDocumentFromPath(pdfPath);
      expect(wrapper.getPageCount(), greaterThan(0));

      wrapper.loadPage(0);
      final width = math.max(1, wrapper.getPageWidth().round());
      final height = math.max(1, wrapper.getPageHeight().round());
      final bytes = wrapper.renderPageAsBytes(width, height);

      expect(bytes.length, width * height * 4);

      wrapper.closePage();
      wrapper.closeDocument();
    }, skip: skipReason);

    test('loadDocumentFromBytes keeps buffer alive until close', () {
      final data = File(pdfPath).readAsBytesSync();
      wrapper.loadDocumentFromBytes(data);
      expect(wrapper.getPageCount(), greaterThan(0));

      wrapper.loadPage(0);
      expect(() => wrapper.getPageWidth(), returnsNormally);
      wrapper.closeDocument();
    }, skip: skipReason);

    test('renderPageToImage applies scale and background', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      final image = wrapper.renderPageToImage(scale: 0.5);
      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
      expect(wrapper.hasOpenPage, isTrue);

      wrapper.closeDocument();
    }, skip: skipReason);

    test('renderRegion returns cropped buffer', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      final region = wrapper.renderRegion(
        startX: 10,
        startY: 15,
        width: 32,
        height: 24,
      );
      expect(region.length, 32 * 24 * 4);

      wrapper.closeDocument();
    }, skip: skipReason);

    test('extractPageText returns textual content', () {
      wrapper.loadDocumentFromPath(pdfPath);

      final directText = wrapper.extractPageText(pageIndex: 0);
      expect(directText.trim(), isNotEmpty);

      wrapper.loadPage(0);
      final currentText = wrapper.extractPageText();
      expect(currentText.trim(), directText.trim());

      wrapper.closeDocument();
    }, skip: skipReason);

    test('renderPageToImageAsync renders on isolate', () async {
      final image = await PdfiumWrap.renderPageToImageAsync(
        config: PdfiumConfig(libraryPath: libraryPath),
        documentPath: pdfPath,
      );
      expect(image.width, greaterThan(0));
      expect(image.height, greaterThan(0));
    }, skip: skipReason);

    test('closePage can be called multiple times safely', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      wrapper.closePage();
      expect(() => wrapper.closePage(), returnsNormally);
      expect(() => wrapper.getPageWidth(), throwsA(isA<PdfiumException>()));

      wrapper.closeDocument();
      expect(() => wrapper.closeDocument(), returnsNormally);
    }, skip: skipReason);

    test('dispose is idempotent and prevents further use', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      wrapper.dispose();
      expect(wrapper.isDisposed, isTrue);
      expect(() => wrapper.dispose(), returnsNormally);
      expect(() => wrapper.getPageCount(), throwsA(isA<StateError>()));
    }, skip: skipReason);

    test('extractPagesFromFile writes selected pages', () async {
      final outDir = Directory.systemTemp.createTempSync('pdfium_split_');
      final outPath = p.join(outDir.path, 'single_page.pdf');

      await PdfiumWrap.extractPagesFromFile(
        config: config,
        sourcePath: pdfPath,
        outputPath: outPath,
        pageIndices: const [0],
        copyViewerPreferences: false,
      );

      final check = PdfiumWrap(config: config);
      check.loadDocumentFromPath(outPath);
      expect(check.getPageCount(), 1);
      check.dispose();

      outDir.deleteSync(recursive: true);
    }, skip: skipReason);

    test('mergeDocuments combines multiple sources', () async {
      final outDir = Directory.systemTemp.createTempSync('pdfium_merge_');
      final mergedPath = p.join(outDir.path, 'merged.pdf');

      wrapper.loadDocumentFromPath(pdfPath);
      final pageCount = wrapper.getPageCount();
      wrapper.closeDocument();
      expect(pageCount, greaterThan(0));

      await PdfiumWrap.mergeDocuments(
        config: config,
        sources: [
          PdfMergeSource(documentPath: pdfPath, pageIndices: const [0]),
          PdfMergeSource(documentPath: pdfPath, pageRange: '1'),
        ],
        outputPath: mergedPath,
        copyViewerPreferences: false,
      );

      final merged = PdfiumWrap(config: config);
      merged.loadDocumentFromPath(mergedPath);
      expect(merged.getPageCount(), 2);
      merged.dispose();

      outDir.deleteSync(recursive: true);
    }, skip: skipReason);

    test('extractPageText throws for out-of-range pageIndex', () {
      wrapper.loadDocumentFromPath(pdfPath);
      final pageCount = wrapper.getPageCount();
      expect(pageCount, greaterThan(0));

      expect(
        () => wrapper.extractPageText(pageIndex: pageCount),
        throwsA(isA<PageException>()),
      );

      wrapper.closeDocument();
    }, skip: skipReason);

    test('savePageAsPng writes a valid PNG file', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      final outDir = Directory.systemTemp.createTempSync('pdfium_png_');
      final outPath = p.join(outDir.path, 'page0.png');

      wrapper.savePageAsPng(outPath, width: 200, height: 200, flush: true);
      final bytes = File(outPath).readAsBytesSync();

      // PNG signature: 89 50 4E 47 0D 0A 1A 0A
      expect(bytes.length, greaterThan(8));
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50);
      expect(bytes[2], 0x4E);
      expect(bytes[3], 0x47);
      expect(bytes[4], 0x0D);
      expect(bytes[5], 0x0A);
      expect(bytes[6], 0x1A);
      expect(bytes[7], 0x0A);

      outDir.deleteSync(recursive: true);
      wrapper.closeDocument();
    }, skip: skipReason);

    test('savePageAsJpg writes a valid JPEG file', () {
      wrapper.loadDocumentFromPath(pdfPath);
      wrapper.loadPage(0);

      final outDir = Directory.systemTemp.createTempSync('pdfium_jpg_');
      final outPath = p.join(outDir.path, 'page0.jpg');

      wrapper.savePageAsJpg(outPath, width: 200, height: 200, flush: true);
      final bytes = File(outPath).readAsBytesSync();

      // JPEG SOI marker: FF D8
      expect(bytes.length, greaterThan(2));
      expect(bytes[0], 0xFF);
      expect(bytes[1], 0xD8);

      outDir.deleteSync(recursive: true);
      wrapper.closeDocument();
    }, skip: skipReason);
  });

  group('GovBR signature rendering', () {
    late PdfiumWrap wrapper;

    setUp(() {
      if (govbrSkipReason != null) {
        return;
      }
      wrapper = PdfiumWrap(
        config: PdfiumConfig(
          libraryPath: libraryPath,
          v8EmbedderSlot: 7,
        ),
      );
    });

    tearDown(() {
      if (govbrSkipReason != null) {
        return;
      }
      wrapper.dispose();
    });

    test(
      'renders visual signature widget appearance stream',
      () {
        wrapper.loadDocumentFromPath(govbrPath);
        expect(wrapper.getPageCount(), greaterThan(0));
        wrapper.loadPage(0);

        final width = math.max(1, wrapper.getPageWidth().round());
        final height = math.max(1, wrapper.getPageHeight().round());

        // Widget signature rect reported for the sample PDF (PDF user space,
        // origin bottom-left) on a ~612x792 page.
        const widgetRect = (
          left: 107.4,
          bottom: 27.0,
          right: 272.4,
          top: 72.0,
        );

        // Force a deterministic background.
        const whiteBackground = 0xFFFFFFFF;
        final bytes = wrapper.renderPageAsBytes(
          width,
          height,
          backgroundColor: whiteBackground,
          renderFormFields: true,
        );

        final nonBgRatio = _nonBackgroundRatioInRect(
          bgraBytes: bytes,
          imageWidth: width,
          imageHeight: height,
          pdfRect: widgetRect,
          backgroundRgb: (255, 255, 255),
        );

        // The signature appearance stream should introduce non-white pixels.
        // Keep threshold conservative to avoid platform-specific raster diffs.
        expect(
          nonBgRatio,
          greaterThan(0.01),
          reason:
              'Expected signature widget region to have visible pixels (non-bg ratio=$nonBgRatio).',
        );
      },
      skip: govbrSkipReason,
    );

    test(
      'auto-renders form widgets when document has AcroForm',
      () {
        wrapper.loadDocumentFromPath(govbrPath);
        wrapper.loadPage(0);

        final width = math.max(1, wrapper.getPageWidth().round());
        final height = math.max(1, wrapper.getPageHeight().round());

        // Same widget rect as the other GovBR test.
        const widgetRect = (
          left: 107.4,
          bottom: 27.0,
          right: 272.4,
          top: 72.0,
        );

        const whiteBackground = 0xFFFFFFFF;
        final bytes = wrapper.renderPageAsBytes(
          width,
          height,
          backgroundColor: whiteBackground,
          // Intentionally false: PdfiumWrap should still render forms
          // automatically when FPDF_GetFormType(document) != 0.
          renderFormFields: false,
        );

        final nonBgRatio = _nonBackgroundRatioInRect(
          bgraBytes: bytes,
          imageWidth: width,
          imageHeight: height,
          pdfRect: widgetRect,
          backgroundRgb: (255, 255, 255),
        );

        expect(
          nonBgRatio,
          greaterThan(0.01),
          reason:
              'Expected widget appearance to be drawn even without renderFormFields=true (non-bg ratio=$nonBgRatio).',
        );
      },
      skip: govbrSkipReason,
    );
  });

  group('jornal.pdf rendering and text extraction', () {
    late PdfiumWrap wrapper;

    setUp(() {
      if (jornalSkipReason != null) {
        return;
      }
      wrapper = PdfiumWrap(
        config: PdfiumConfig(
          libraryPath: libraryPath,
          v8EmbedderSlot: 7,
        ),
      );
    });

    tearDown(() {
      if (jornalSkipReason != null) {
        return;
      }
      wrapper.dispose();
    });

    test('renders first page with visible content', () {
      wrapper.loadDocumentFromPath(jornalPath);
      expect(wrapper.getPageCount(), greaterThan(0));

      wrapper.loadPage(0);
      final pageW = wrapper.getPageWidth();
      final pageH = wrapper.getPageHeight();
      expect(pageW, greaterThan(0));
      expect(pageH, greaterThan(0));

      // Downscale a bit to keep the test fast.
      final width = math.max(1, (pageW * 0.6).round());
      final height = math.max(1, (pageH * 0.6).round());

      const whiteBackground = 0xFFFFFFFF;
      final bytes = wrapper.renderPageAsBytes(
        width,
        height,
        backgroundColor: whiteBackground,
        renderFormFields: true,
      );
      expect(bytes.length, width * height * 4);

      final nonBgRatio = _nonBackgroundRatioInRect(
        bgraBytes: bytes,
        imageWidth: width,
        imageHeight: height,
        pdfRect: (
          left: 0,
          bottom: 0,
          right: width.toDouble(),
          top: height.toDouble(),
        ),
        backgroundRgb: (255, 255, 255),
      );

      // Newspaper pages are usually dense; keep threshold conservative.
      expect(
        nonBgRatio,
        greaterThan(0.01),
        reason:
            'Expected jornal.pdf first page to render non-white content (non-bg ratio=$nonBgRatio).',
      );
    }, skip: jornalSkipReason);

    test('extractPageText returns non-empty text for first page', () {
      wrapper.loadDocumentFromPath(jornalPath);

      final directText = wrapper.extractPageText(pageIndex: 0);
      final normalized =
          directText.replaceAll(RegExp(r'\s+'), ' ').trim();

      expect(
        normalized,
        isNotEmpty,
        reason: 'Expected jornal.pdf to contain extractable text on page 1.',
      );
      expect(
        normalized.length,
        greaterThan(20),
        reason:
            'Expected jornal.pdf extracted text to have meaningful length (got ${normalized.length}).',
      );
      expect(
        normalized,
        contains(RegExp(r'[A-Za-zÀ-ÖØ-öø-ÿ0-9]')),
        reason: 'Expected jornal.pdf extracted text to contain letters/digits.',
      );

      wrapper.loadPage(0);
      final currentText = wrapper.extractPageText();
      expect(currentText.replaceAll(RegExp(r'\s+'), ' ').trim(), normalized);

      wrapper.closeDocument();
    }, skip: jornalSkipReason);
  });

  group('3_ass.pdf rendering', () {
    late PdfiumWrap wrapper;

    setUp(() {
      if (ass3SkipReason != null) {
        return;
      }
      wrapper = PdfiumWrap(
        config: PdfiumConfig(
          libraryPath: libraryPath,
          v8EmbedderSlot: 7,
        ),
      );
    });

    tearDown(() {
      if (ass3SkipReason != null) {
        return;
      }
      wrapper.dispose();
    });

    test('contains at least one signature object', () {
      final lib = DynamicLibrary.open(libraryPath!);
      final pdfium = PDFiumBindings(lib);

      final pathPtr = ass3Path.toNativeUtf8(allocator: calloc).cast<Char>();
      FPDF_DOCUMENT doc = nullptr;
      try {
        doc = pdfium.FPDF_LoadDocument(pathPtr, nullptr);
        expect(doc, isNot(equals(nullptr)));
        final count = pdfium.FPDF_GetSignatureCount(doc);
        expect(count, greaterThan(0));
      } finally {
        calloc.free(pathPtr);
        if (doc != nullptr) {
          pdfium.FPDF_CloseDocument(doc);
        }
      }
    }, skip: ass3SkipReason);

    test('renders visual signature block (form widget)', () {
      final lib = DynamicLibrary.open(libraryPath!);
      final pdfium = PDFiumBindings(lib);

      final pathPtr = ass3Path.toNativeUtf8(allocator: calloc).cast<Char>();
      FPDF_DOCUMENT doc = nullptr;
      FPDF_PAGE page = nullptr;
      late final _TestFormFillEnv env;

      try {
        doc = pdfium.FPDF_LoadDocument(pathPtr, nullptr);
        expect(doc, isNot(equals(nullptr)));

        final signatureCount = pdfium.FPDF_GetSignatureCount(doc);
        expect(signatureCount, greaterThan(0));

        final formType = pdfium.FPDF_GetFormType(doc);

        page = pdfium.FPDF_LoadPage(doc, 0);
        expect(page, isNot(equals(nullptr)));

        final pageWidth = pdfium.FPDF_GetPageWidth(page);
        final pageHeight = pdfium.FPDF_GetPageHeight(page);
        expect(pageWidth, greaterThan(0));
        expect(pageHeight, greaterThan(0));

        _PdfRect? signatureRect;
        if (formType != 0) {
          env = _TestFormFillEnv.create(pdfium: pdfium, document: doc);
          env.attachPage(page: page, pageIndex: 0);
          signatureRect = _scanSignatureWidgetRect(
            pdfium: pdfium,
            env: env,
            page: page,
            pageWidth: pageWidth,
            pageHeight: pageHeight,
          );
        }

        // Render using the wrapper (this should draw forms via FFLDraw).
        wrapper.loadDocumentFromPath(ass3Path);
        wrapper.loadPage(0);
        final width = math.max(1, wrapper.getPageWidth().round());
        final height = math.max(1, wrapper.getPageHeight().round());
        const whiteBackground = 0xFFFFFFFF;
        final bytes = wrapper.renderPageAsBytes(
          width,
          height,
          backgroundColor: whiteBackground,
          renderFormFields: true,
        );

        final rect =
            signatureRect ??
            // Fallback when the PDF is signed but doesn't expose a signature
            // widget through form-field hit testing (e.g. a stamped signature).
            (
              left: pageWidth * 0.5,
              bottom: 0.0,
              right: pageWidth,
              top: pageHeight * 0.25,
            );
        final nonBgRatio = _nonBackgroundRatioInPdfRect(
          bgraBytes: bytes,
          imageWidth: width,
          imageHeight: height,
          pageWidth: pageWidth,
          pageHeight: pageHeight,
          pdfRect: rect,
          backgroundRgb: (255, 255, 255),
        );

        expect(
          nonBgRatio,
          greaterThan(0.01),
          reason:
              'Expected signature widget region to have visible pixels (non-bg ratio=$nonBgRatio).',
        );
      } finally {
        calloc.free(pathPtr);
        try {
          if (page != nullptr) {
            // Ensure FORM_OnBeforeClosePage is invoked for consistency.
            if (_TestFormFillEnv.maybeForDoc(doc) case final existing?) {
              existing.detachPage(page);
            }
            pdfium.FPDF_ClosePage(page);
          }
        } finally {
          if (doc != nullptr) {
            pdfium.FPDF_CloseDocument(doc);
          }
          _TestFormFillEnv.disposeForDoc(doc);
        }
      }
    }, skip: ass3SkipReason);
  });
}

double _nonBackgroundRatioInRect({
  required List<int> bgraBytes,
  required int imageWidth,
  required int imageHeight,
  required _PdfRect pdfRect,
  required (int r, int g, int b) backgroundRgb,
}) {
  if (imageWidth <= 0 || imageHeight <= 0) {
    return 0;
  }
  if (bgraBytes.length < imageWidth * imageHeight * 4) {
    return 0;
  }

  // Convert PDF rect (origin bottom-left) to image pixel rect (origin top-left).
  final left = pdfRect.left.round().clamp(0, imageWidth);
  final right = pdfRect.right.round().clamp(0, imageWidth);
  final top = (imageHeight - pdfRect.top).round().clamp(0, imageHeight);
  final bottom = (imageHeight - pdfRect.bottom).round().clamp(0, imageHeight);

  final x0 = math.min(left, right);
  final x1 = math.max(left, right);
  final y0 = math.min(top, bottom);
  final y1 = math.max(top, bottom);

  final w = x1 - x0;
  final h = y1 - y0;
  if (w <= 0 || h <= 0) {
    return 0;
  }

  var nonBg = 0;
  final total = w * h;

  const channelEpsilon = 3;

  for (var y = y0; y < y1; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * imageWidth + x) * 4;
      final b = bgraBytes[i];
      final g = bgraBytes[i + 1];
      final r = bgraBytes[i + 2];

      final isBackground =
          (r - backgroundRgb.$1).abs() <= channelEpsilon &&
              (g - backgroundRgb.$2).abs() <= channelEpsilon &&
              (b - backgroundRgb.$3).abs() <= channelEpsilon;
      if (!isBackground) {
        nonBg++;
      }
    }
  }

  return nonBg / total;
}

double _nonBackgroundRatioInPdfRect({
  required List<int> bgraBytes,
  required int imageWidth,
  required int imageHeight,
  required double pageWidth,
  required double pageHeight,
  required _PdfRect pdfRect,
  required (int r, int g, int b) backgroundRgb,
}) {
  // Map PDF user space (origin bottom-left) to image pixels (origin top-left).
  final leftPx = (pdfRect.left / pageWidth * imageWidth).round();
  final rightPx = (pdfRect.right / pageWidth * imageWidth).round();
  final topPx = ((1 - (pdfRect.top / pageHeight)) * imageHeight).round();
  final bottomPx = ((1 - (pdfRect.bottom / pageHeight)) * imageHeight).round();

  final mapped = (
    left: leftPx.toDouble(),
    bottom: bottomPx.toDouble(),
    right: rightPx.toDouble(),
    top: topPx.toDouble(),
  );
  return _nonBackgroundRatioInRect(
    bgraBytes: bgraBytes,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    pdfRect: mapped,
    backgroundRgb: backgroundRgb,
  );
}

_PdfRect? _scanSignatureWidgetRect({
  required PDFiumBindings pdfium,
  required _TestFormFillEnv env,
  required FPDF_PAGE page,
  required double pageWidth,
  required double pageHeight,
}) {
  // Coarse grid scan using PDFium's form-fill hit testing.
  final step = math.max(4.0, math.min(pageWidth, pageHeight) / 120.0);

  double? minX;
  double? maxX;
  double? minY;
  double? maxY;

  for (var y = 0.0; y <= pageHeight; y += step) {
    for (var x = 0.0; x <= pageWidth; x += step) {
      final fieldType =
          pdfium.FPDFPage_HasFormFieldAtPoint(env.handle, page, x, y);
      if (fieldType != FPDF_FORMFIELD_SIGNATURE) {
        continue;
      }
      minX = minX == null ? x : math.min(minX, x);
      maxX = maxX == null ? x : math.max(maxX, x);
      minY = minY == null ? y : math.min(minY, y);
      maxY = maxY == null ? y : math.max(maxY, y);
    }
  }

  if (minX == null || maxX == null || minY == null || maxY == null) {
    return null;
  }

  final pad = step * 2;
  return (
    left: (minX - pad).clamp(0, pageWidth),
    bottom: (minY - pad).clamp(0, pageHeight),
    right: (maxX + pad).clamp(0, pageWidth),
    top: (maxY + pad).clamp(0, pageHeight),
  );
}

final class _TestFormFillEnv {
  _TestFormFillEnv._(
    this.pdfium,
    this.document,
    this.handle,
    this.info,
    this._stateKey,
  );

  final PDFiumBindings pdfium;
  final FPDF_DOCUMENT document;
  final FPDF_FORMHANDLE handle;
  final Pointer<FPDF_FORMFILLINFO> info;
  final int _stateKey;

  static final Map<int, _TestFormFillState> _states = <int, _TestFormFillState>{};
  static final Map<int, _TestFormFillEnv> _envByDoc = <int, _TestFormFillEnv>{};

  static _TestFormFillEnv? maybeForDoc(FPDF_DOCUMENT doc) =>
      _envByDoc[doc.address];

  static void disposeForDoc(FPDF_DOCUMENT doc) {
    final env = _envByDoc.remove(doc.address);
    if (env == null) {
      return;
    }
    try {
      if (env.handle != nullptr) {
        env.pdfium.FPDFDOC_ExitFormFillEnvironment(env.handle);
      }
    } finally {
      _states.remove(env._stateKey);
      calloc.free(env.info);
    }
  }

  static _TestFormFillEnv create({
    required PDFiumBindings pdfium,
    required FPDF_DOCUMENT document,
  }) {
    final info = calloc<FPDF_FORMFILLINFO>();
    info.ref.version = 1;
    info.ref.xfa_disabled = 1;

    info.ref.Release = Pointer.fromFunction<Void Function(Pointer<FPDF_FORMFILLINFO>)>(
      _testFormFillRelease,
    );
    info.ref.FFI_Invalidate = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, Double, Double, Double, Double)>(
      _testFormFillInvalidate,
    );
    info.ref.FFI_OutputSelectedRect = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE, Double, Double, Double, Double)>(
      _testFormFillInvalidate,
    );
    info.ref.FFI_SetCursor = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, Int)>(
      _testFormFillSetCursor,
    );
    info.ref.FFI_SetTimer = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, Int, TimerCallback)>(
      _testFormFillSetTimer,
      0,
    );
    info.ref.FFI_KillTimer = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, Int)>(
      _testFormFillKillTimer,
    );
    info.ref.FFI_GetLocalTime = nullptr;
    info.ref.FFI_OnChange = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>)>(
      _testFormFillOnChange,
    );
    info.ref.FFI_GetPage = Pointer.fromFunction<
        FPDF_PAGE Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, Int)>(
      _testFormFillGetPage,
    );
    info.ref.FFI_GetCurrentPage = Pointer.fromFunction<
        FPDF_PAGE Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT)>(
      _testFormFillGetCurrentPage,
    );
    info.ref.FFI_GetRotation = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_PAGE)>(
      _testFormFillGetRotation,
      0,
    );
    info.ref.FFI_ExecuteNamedAction = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_BYTESTRING)>(
      _testFormFillExecuteNamedAction,
    );
    info.ref.FFI_SetTextFieldFocus = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_WIDESTRING, FPDF_DWORD, FPDF_BOOL)>(
      _testFormFillSetTextFieldFocus,
    );
    info.ref.FFI_DoURIAction = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_BYTESTRING)>(
      _testFormFillDoUriAction,
    );
    info.ref.FFI_DoGoToAction = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, Int, Int, Pointer<Float>, Int)>(
      _testFormFillDoGoToAction,
    );
    info.ref.FFI_GetCurrentPageIndex = Pointer.fromFunction<
        Int Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT)>(
      _testFormFillGetCurrentPageIndex,
      0,
    );
    info.ref.FFI_SetCurrentPage = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, Int)>(
      _testFormFillSetCurrentPage,
    );
    info.ref.FFI_GotoURL = Pointer.fromFunction<
        Void Function(Pointer<FPDF_FORMFILLINFO>, FPDF_DOCUMENT, FPDF_WIDESTRING)>(
      _testFormFillGotoUrl,
    );

    final handle = pdfium.FPDFDOC_InitFormFillEnvironment(document, info);
    pdfium.FPDF_SetFormFieldHighlightAlpha(handle, 0);

    final stateKey = info.address;
    _states[stateKey] = _TestFormFillState(document: document);
    final env = _TestFormFillEnv._(pdfium, document, handle, info, stateKey);
    _envByDoc[document.address] = env;
    return env;
  }

  void attachPage({required FPDF_PAGE page, required int pageIndex}) {
    final state = _states[_stateKey];
    if (state == null) {
      return;
    }
    state.currentPage = page;
    state.currentPageIndex = pageIndex;
    pdfium.FORM_OnAfterLoadPage(page, handle);
  }

  void detachPage(FPDF_PAGE page) {
    pdfium.FORM_OnBeforeClosePage(page, handle);
    final state = _states[_stateKey];
    if (state != null && identical(state.currentPage, page)) {
      state.currentPage = nullptr;
      state.currentPageIndex = 0;
    }
  }
}

final class _TestFormFillState {
  _TestFormFillState({required this.document});

  final FPDF_DOCUMENT document;
  FPDF_PAGE currentPage = nullptr;
  int currentPageIndex = 0;
}

final Map<int, Timer> _testTimers = <int, Timer>{};
int _testTimerSeq = 1;

void _testFormFillRelease(Pointer<FPDF_FORMFILLINFO> pThis) {}

void _testFormFillInvalidate(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
  double left,
  double top,
  double right,
  double bottom,
) {}

void _testFormFillSetCursor(Pointer<FPDF_FORMFILLINFO> pThis, int nCursorType) {}

int _testFormFillSetTimer(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int uElapse,
  TimerCallback lpTimerFunc,
) {
  final id = _testTimerSeq++;
  final cb = lpTimerFunc.asFunction<DartTimerCallbackFunction>();
  _testTimers[id] = Timer(Duration(milliseconds: uElapse), () {
    try {
      cb(id);
    } finally {
      _testTimers.remove(id);
    }
  });
  return id;
}

void _testFormFillKillTimer(Pointer<FPDF_FORMFILLINFO> pThis, int nTimerID) {
  _testTimers.remove(nTimerID)?.cancel();
}

void _testFormFillOnChange(Pointer<FPDF_FORMFILLINFO> pThis) {}

FPDF_PAGE _testFormFillGetPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  int nPageIndex,
) {
  final state = _TestFormFillEnv._states[pThis.address];
  if (state == null) {
    return nullptr;
  }
  if (state.document.address != document.address) {
    return nullptr;
  }
  if (state.currentPage != nullptr && state.currentPageIndex == nPageIndex) {
    return state.currentPage;
  }
  return nullptr;
}

FPDF_PAGE _testFormFillGetCurrentPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
) {
  final state = _TestFormFillEnv._states[pThis.address];
  if (state == null) {
    return nullptr;
  }
  if (state.document.address != document.address) {
    return nullptr;
  }
  return state.currentPage;
}

int _testFormFillGetRotation(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_PAGE page,
) {
  return 0;
}

void _testFormFillExecuteNamedAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_BYTESTRING namedAction,
) {}

void _testFormFillSetTextFieldFocus(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_WIDESTRING value,
  int valueLen,
  int isFocus,
) {}

void _testFormFillDoUriAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_BYTESTRING bsURI,
) {}

void _testFormFillDoGoToAction(
  Pointer<FPDF_FORMFILLINFO> pThis,
  int nPageIndex,
  int zoomMode,
  Pointer<Float> fPosArray,
  int sizeofArray,
) {}

int _testFormFillGetCurrentPageIndex(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
) {
  final state = _TestFormFillEnv._states[pThis.address];
  if (state == null) {
    return 0;
  }
  return state.document.address == document.address ? state.currentPageIndex : 0;
}

void _testFormFillSetCurrentPage(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  int iCurPage,
) {}

void _testFormFillGotoUrl(
  Pointer<FPDF_FORMFILLINFO> pThis,
  FPDF_DOCUMENT document,
  FPDF_WIDESTRING wsURL,
) {}

String? _resolveLibraryPath() {
  final envOverride = Platform.environment['PDFIUM_LIB_PATH'];
  if (envOverride != null && envOverride.isNotEmpty) {
    return envOverride;
  }

  final root = Directory.current.path;
  final candidates = <String>[];
  if (Platform.isWindows) {
    candidates.add(p.join(root, 'pdfium.dll'));
  } else if (Platform.isLinux || Platform.isAndroid) {
    candidates.add(p.join(root, 'libpdfium.so'));
  } else if (Platform.isMacOS) {
    candidates.add(p.join(root, 'libpdfium.dylib'));
  }

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}
