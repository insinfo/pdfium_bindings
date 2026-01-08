import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:test/test.dart';

void main() {
  final libraryPath = _resolveLibraryPath();
  final jornalPath = p.join(
    Directory.current.path,
    'test',
    'assets',
    'jornal.pdf',
  );

  final skipReason = libraryPath == null
      ? 'pdfium native library not found in project root'
      : !File(jornalPath).existsSync()
          ? 'sample PDF not found at $jornalPath'
          : null;

  group('PdfiumService (file lock)', () {
    test(
      'serializes access across isolates',
      () async {
        final events = await _runTwoIsolatesAndCollectEvents(
          entryPoint: _pdfiumServiceWorker,
          argsBuilder: (sendPort, id) => {
            'sendPort': sendPort,
            'id': id,
            // Touch the PDFium library to ensure the service actually
            // initializes PdfiumWrap.
            'pdfPath': jornalPath,
          },
        );

        final intervals = _intervalsFromEvents(events);
        expect(intervals.length, 2);
        expect(
          _intervalsDoNotOverlap(intervals[0], intervals[1]),
          isTrue,
          reason: 'Expected file mutex to serialize across isolates. '
              'Got intervals: $intervals',
        );
      },
      skip: skipReason,
    );

    test(
      'dispose is safe and allows reuse',
      () async {
        final service = PdfiumService();
        await service.run((pdf) {
          pdf.loadDocumentFromPath(jornalPath);
          final count = pdf.getPageCount();
          pdf.closeDocument();
          return count;
        });

        await service.dispose();

        final count2 = await service.run((pdf) {
          pdf.loadDocumentFromPath(jornalPath);
          final count = pdf.getPageCount();
          pdf.closeDocument();
          return count;
        });
        expect(count2, greaterThan(0));

        await service.dispose();
      },
      skip: skipReason,
    );
  });

  group('PdfiumServiceMutex (native_synchronization)', () {
    test(
      'serializes access across isolates via shared sendable mutex',
      () async {
        final root = PdfiumServiceMutex();
        final handle = root.toSendable();

        final events = await _runTwoIsolatesAndCollectEvents(
          entryPoint: _pdfiumServiceMutexWorker,
          argsBuilder: (sendPort, id) => {
            'sendPort': sendPort,
            'id': id,
            'handle': handle,
            'pdfPath': jornalPath,
          },
        );

        final intervals = _intervalsFromEvents(events);
        expect(intervals.length, 2);
        expect(
          _intervalsDoNotOverlap(intervals[0], intervals[1]),
          isTrue,
          reason: 'Expected native mutex to serialize across isolates. '
              'Got intervals: $intervals',
        );

        root.dispose();
      },
      skip: skipReason,
    );

    test(
      'fromSendable creates a functional service',
      () {
        final root = PdfiumServiceMutex();
        final handle = root.toSendable();

        final other = PdfiumServiceMutex.fromSendable(handle);
        final count = other.run((pdf) {
          pdf.loadDocumentFromPath(jornalPath);
          final c = pdf.getPageCount();
          pdf.closeDocument();
          return c;
        });

        expect(count, greaterThan(0));
        root.dispose();
        other.dispose();
      },
      skip: skipReason,
    );
  });
}

/// Worker for [PdfiumService] (file mutex). Must be top-level for Isolate.spawn.
Future<void> _pdfiumServiceWorker(Map<String, Object?> args) async {
  final sendPort = args['sendPort'] as SendPort;
  final id = args['id'] as int;
  final pdfPath = args['pdfPath'] as String;

  final service = PdfiumService();

  try {
    await service.run((pdf) async {
      // Touch PDFium so this test fails if PdfiumWrap init is broken.
      pdf.loadDocumentFromPath(pdfPath);
      pdf.closeDocument();

      sendPort.send(_event(id, 'start'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      sendPort.send(_event(id, 'end'));
      return 0;
    });
  } finally {
    // Avoid relying on finalizers during isolate teardown.
    await service.dispose();
  }
}

/// Worker for [PdfiumServiceMutex]. Must be top-level for Isolate.spawn.
void _pdfiumServiceMutexWorker(Map<String, Object?> args) {
  final sendPort = args['sendPort'] as SendPort;
  final id = args['id'] as int;
  final handle = args['handle'] as PdfiumServiceSendable;
  final pdfPath = args['pdfPath'] as String;

  final service = PdfiumServiceMutex.fromSendable(handle);

  try {
    // Must remain synchronous (cannot span an await).
    service.run((pdf) {
      pdf.loadDocumentFromPath(pdfPath);
      pdf.closeDocument();

      sendPort.send(_event(id, 'start'));
      sleep(const Duration(milliseconds: 200));
      sendPort.send(_event(id, 'end'));
      return 0;
    });
  } finally {
    // Avoid relying on finalizers during isolate teardown.
    service.dispose();
  }
}

Map<String, Object> _event(int id, String type) {
  return <String, Object>{
    'id': id,
    'type': type,
    'ts': DateTime.now().microsecondsSinceEpoch,
  };
}

typedef _Interval = ({int id, int startUs, int endUs});

List<_Interval> _intervalsFromEvents(List<Map<String, Object?>> events) {
  final byId = <int, Map<String, int>>{};
  for (final e in events) {
    final id = e['id'] as int;
    final type = e['type'] as String;
    final ts = e['ts'] as int;
    byId.putIfAbsent(id, () => <String, int>{})[type] = ts;
  }

  final intervals = <_Interval>[];
  for (final entry in byId.entries) {
    final start = entry.value['start'];
    final end = entry.value['end'];
    if (start == null || end == null) {
      continue;
    }
    intervals.add((id: entry.key, startUs: start, endUs: end));
  }

  intervals.sort((a, b) => a.startUs.compareTo(b.startUs));
  return intervals;
}

bool _intervalsDoNotOverlap(_Interval a, _Interval b) {
  return a.endUs <= b.startUs || b.endUs <= a.startUs;
}

Future<List<Map<String, Object?>>> _runTwoIsolatesAndCollectEvents({
  required FutureOr<void> Function(Map<String, Object?> args) entryPoint,
  required Map<String, Object?> Function(SendPort sendPort, int id) argsBuilder,
}) async {
  final receivePort = ReceivePort();
  final errorPort = ReceivePort();
  final exitPort = ReceivePort();

  final events = <Map<String, Object?>>[];
  final errors = <Object?>[];
  var exitCount = 0;

  late final StreamSubscription receiveSub;
  late final StreamSubscription errorSub;
  late final StreamSubscription exitSub;

  receiveSub = receivePort.listen((message) {
    if (message is Map) {
      events.add(message.cast<String, Object?>());
    }
  });

  errorSub = errorPort.listen((message) {
    errors.add(message);
  });

  exitSub = exitPort.listen((_) {
    exitCount++;
  });

  try {
    await Isolate.spawn<Map<String, Object?>>(
      entryPoint,
      argsBuilder(receivePort.sendPort, 1),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );
    await Isolate.spawn<Map<String, Object?>>(
      entryPoint,
      argsBuilder(receivePort.sendPort, 2),
      onError: errorPort.sendPort,
      onExit: exitPort.sendPort,
    );

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (exitCount < 2 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    expect(exitCount, 2, reason: 'Worker isolates did not exit in time.');
    expect(errors, isEmpty, reason: 'Worker isolates errored: $errors');

    return events;
  } finally {
    await receiveSub.cancel();
    await errorSub.cancel();
    await exitSub.cancel();
    receivePort.close();
    errorPort.close();
    exitPort.close();
  }
}

String? _resolveLibraryPath() {
  final dll = File(p.join(Directory.current.path, 'pdfium.dll'));
  if (dll.existsSync()) {
    return dll.path;
  }
  return null;
}
