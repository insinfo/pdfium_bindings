import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';

/// Demonstrates issue #3: PDFium cannot service multiple isolates in parallel.
///
/// Run this example and observe that attempting to render the same document in
/// two isolates at once either times out or executes strictly sequentially.
Future<void> main() async {
  final libraryPath = _resolveLibraryPath();
  final documentPath = p.join(Directory.current.path, '1417.pdf');
  if (!File(documentPath).existsSync()) {
    stderr.writeln('Sample PDF not found at $documentPath');
    exit(1);
  }

  final sw = Stopwatch()..start();
  final futures = List.generate(
    2,
    (index) => _renderInWorker(
      libraryPath: libraryPath,
      documentPath: documentPath,
      workerId: index,
    ),
  );

  try {
    await Future.wait(futures).timeout(const Duration(seconds: 10));
    stdout.writeln(
      'Both isolates finished in ${sw.elapsed}. If this example hangs or times '
      'out on your platform, PDFium is exhibiting the known global isolation '
      'limitation (issue #3).',
    );
  } on TimeoutException {
    stderr.writeln(
      "Timed out waiting for parallel renders. This highlights PDFium's "
      'single-threaded limitation (issue #3).',
    );
  }
}

Future<void> _renderInWorker({
  required String libraryPath,
  required String documentPath,
  required int workerId,
}) async {
  await Isolate.run(() {
    final config = PdfiumConfig(libraryPath: libraryPath);
    final wrapper = PdfiumWrap(config: config);
    try {
      wrapper.loadDocumentFromPath(documentPath);
      wrapper.loadPage(0);
      wrapper.renderPageAsBytes(256, 256);
      stdout.writeln('Worker $workerId completed render.');
    } finally {
      wrapper.dispose();
    }
  });
}

String _resolveLibraryPath() {
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
  throw MissingLibraryException(path: candidates.first);
}
