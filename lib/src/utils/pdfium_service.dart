// file: pdfium_service.dart
import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';

/// Service that serializes PDFium usage across isolates via a filesystem lock.
///
/// See the README section “Managing isolate contention” for a comparison with
/// the [`PdfiumServiceMutex`] variant that relies on `native_synchronization`.
/// This `_FileMutex` flavour is cross-process and `await`-friendly but slower
/// and more brittle than the in-process mutex.
class PdfiumService {
  // singleton por processo (no Dart isso já resolve para o mesmo objeto
  // dentro do mesmo isolate; o mutex com nome garante a coordenação
  // entre isolates).
  static final PdfiumService _instance = PdfiumService._internal();
  factory PdfiumService() => _instance;

  PdfiumService._internal();

  final _FileMutex _mutex = _FileMutex('pdfium_bindings_global.lock');

  PdfiumWrap? _pdfium;

  /// Use isto em qualquer lugar que precise do PDFium.
  /// Exemplo:
  ///
  ///   await PdfiumService().run((pdf) {
  ///     final doc = pdf.loadDocumentFromPath('1417.pdf');
  ///     pdf.loadPage(0);
  ///     return pdf.renderPageAsBytes(256, 256);
  ///   });
  ///
  Future<T> run<T>(FutureOr<T> Function(PdfiumWrap pdf) action) {
    // garante exclusão mútua entre isolates e threads
    return _mutex.runExclusive(() async {
      _pdfium ??= _createPdfium();
      return await Future.sync(() => action(_pdfium!));
    });
  }

  /// Se quiser desmontar o PDFium no final do app.
  Future<void> dispose() {
    return _mutex.runExclusive(() async {
      _pdfium?.dispose();
      _pdfium = null;
    });
  }

  PdfiumWrap _createPdfium({PdfiumConfig? config}) {
    return PdfiumWrap(config: config ?? const PdfiumConfig());
  }
}

class _FileMutex {
  _FileMutex(String name)
      : _lockFile = File(p.join(Directory.systemTemp.path, name));

  final File _lockFile;

  Future<T> runExclusive<T>(FutureOr<T> Function() action) async {
    _lockFile.createSync(recursive: true);
    final handle = await _lockFile.open(mode: FileMode.write);
    try {
      await handle.lock(FileLock.blockingExclusive);
      try {
        return await Future.sync(action);
      } finally {
        await handle.unlock();
      }
    } finally {
      await handle.close();
    }
  }
}
