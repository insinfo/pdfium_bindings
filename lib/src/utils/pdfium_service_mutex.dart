// file: pdfium_service.dart
import 'dart:io';

import 'package:native_synchronization/primitives.dart';
import 'package:native_synchronization/sendable.dart';
import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';

/// Sendable handle that carries the mutex across isolates.
/// Note that it does not transport a `PdfiumWrap`, only the locking primitive.
class PdfiumServiceSendable {
  final Sendable<Mutex> mutexSendable;
  const PdfiumServiceSendable(this.mutexSendable);
}

/// Service that grants exclusive PDFium access using `native_synchronization`.
///
/// Important details:
/// - [run] must stay synchronous: the mutex cannot span an `await`.
/// - Create the service in the root isolate, call [toSendable], and ship the
///   handle to worker isolates so they all contend on the same lock.
///
/// Refer to the README “Managing isolate contention” section for a quick
/// comparison with the `_FileMutex` flavour.
class PdfiumServiceMutex {
  static PdfiumServiceMutex? _instance;

  final Mutex _mutex;
  PdfiumWrap? _pdfium;

  /// Factory padrão: cria (ou reaproveita) o serviço neste isolate.
  factory PdfiumServiceMutex({Mutex? sharedMutex}) {
    if (_instance != null) {
      return _instance!;
    }
    final m = sharedMutex ?? Mutex();
    _instance = PdfiumServiceMutex._(m);
    return _instance!;
  }

  PdfiumServiceMutex._(this._mutex);

  /// Returns a sendable handle so another isolate can reuse the same mutex.
  PdfiumServiceSendable toSendable() {
    return PdfiumServiceSendable(_mutex.asSendable);
  }

  /// Rehydrates (or obtains) the service in this isolate from a sendable handle.
  factory PdfiumServiceMutex.fromSendable(PdfiumServiceSendable handle) {
    final mutex = handle.mutexSendable.materialize();
    return PdfiumServiceMutex(sharedMutex: mutex);
  }

  /// Executes a protected operation against PDFium.
  T run<T>(T Function(PdfiumWrap pdf) action) {
    return _mutex.runLocked(() {
      _pdfium ??= _createPdfium();
      return action(_pdfium!);
    });
  }

  /// Disposes PDFium (optional).
  void dispose() {
    _mutex.runLocked(() {
      _pdfium?.dispose();
      _pdfium = null;
    });
  }

  PdfiumWrap _createPdfium() {
    final libraryPath = _resolveLibraryPath();
    final config = PdfiumConfig(libraryPath: libraryPath);
    return PdfiumWrap(config: config);
  }

  String _resolveLibraryPath() {
    final root = Directory.current.path;
    final candidates = <String>[
      p.join(root, 'pdfium.dll'),
      p.join(root, 'libpdfium.so'),
      p.join(root, 'libpdfium.dylib'),
    ];
    for (final c in candidates) {
      if (File(c).existsSync()) {
        return c;
      }
    }
    throw MissingLibraryException(path: candidates.first);
  }
}
