// file: main.dart
import 'dart:async';
import 'dart:isolate';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/src/utils/pdfium_service.dart';

Future<void> main() async {
  final pdfPath = p.join(Directory.current.path, '1417.pdf');

  // dispara duas tarefas "em paralelo"
  final futures = List.generate(2, (i) {
    return Isolate.run(() async {
      final service = PdfiumService();
      await service.run((pdf) {
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
