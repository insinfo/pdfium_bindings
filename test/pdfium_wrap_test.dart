import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:test/test.dart';

void main() {
  final libraryPath = _resolveLibraryPath();
  final pdfPath = p.join(Directory.current.path, '1417.pdf');
  final pdfExists = File(pdfPath).existsSync();
  final skipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !pdfExists
          ? 'sample PDF not found at $pdfPath'
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
  });
}

String? _resolveLibraryPath() {
  final root = Directory.current.path;
  final candidates = <String>[
    p.join(root, 'pdfium.dll'),
    p.join(root, 'libpdfium.so'),
    p.join(root, 'libpdfium.dylib'),
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}
