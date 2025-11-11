// file: main.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/src/utils/pdfium_service_mutex.dart';

Future<void> main() async {
  final pdfPath = p.join(Directory.current.path, '1417.pdf');
// isolate principal
  final service = PdfiumServiceMutex();
  final handle = service.toSendable();
// enviar `handle` pelo SendPort...

  // dispara duas tarefas "em paralelo"
  final futures = List.generate(2, (i) {
    return Isolate.run(() async {
      // no outro isolate
      final service2 = PdfiumServiceMutex.fromSendable(handle);
      service2.run((pdf) {
        pdf.loadDocumentFromPath(pdfPath);
        pdf.loadPage(0);
        final bytes = pdf.renderPageAsBytes(256, 256);
        stdout.writeln('Isolate $i renderizou ${bytes.length} bytes');
        return null;
      });
    });
  });

  await Future.wait(futures);
  stdout.writeln('Tudo terminou sem crash.');
}
