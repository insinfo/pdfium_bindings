// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() {
  final root = Directory.current.path;
  final libraryPath = path.join(root, 'pdfium.dll');
  final pdfPath = path.join(root, 'jornal.pdf');

  if (!File(libraryPath).existsSync()) {
    stderr.writeln('Missing pdfium.dll at $libraryPath');
    exit(1);
  }
  if (!File(pdfPath).existsSync()) {
    stderr.writeln('Missing jornal.pdf at $pdfPath');
    exit(1);
  }

  final wrapper = PdfiumWrap(config: PdfiumConfig(libraryPath: libraryPath));
  try {
    wrapper.loadDocumentFromPath(pdfPath);
    final text = wrapper.extractPageText(pageIndex: 0);

    if (text.trim().isEmpty) {
      print('Nenhum texto encontrado na página 1.');
    } else {
      print('Texto da página 1:\n$text');
    }
  } finally {
    wrapper.closeDocument();
    wrapper.dispose();
  }
}
