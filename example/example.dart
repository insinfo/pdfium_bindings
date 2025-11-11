// ignore_for_file: avoid_print

import 'dart:io';

import 'package:image/image.dart';
import 'package:path/path.dart' as path;
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() {
  final stopwatch = Stopwatch()..start();
  final libraryPath = path.join(Directory.current.path, 'pdfium.dll');
  final pdfPath = path.join(Directory.current.path, '1417.pdf');
  if (!File(libraryPath).existsSync()) {
    throw Exception('Missing pdfium.dll at $libraryPath');
  }
  if (!File(pdfPath).existsSync()) {
    throw Exception('Missing sample PDF at $pdfPath');
  }

  final wrapper = PdfiumWrap(config: PdfiumConfig(libraryPath: libraryPath));

  try {
    wrapper.loadDocumentFromPath(pdfPath);
    final pageCount = wrapper.getPageCount();
    print('pageCount: $pageCount');

    wrapper.loadPage(0);
    final width = wrapper.getPageWidth().round();
    final height = wrapper.getPageHeight().round();
    print('page Width: $width');
    print('page Height: $height');

    final image = wrapper.renderPageToImage();

    File('out.png').writeAsBytesSync(encodePng(image));
  } finally {
    wrapper.closePage();
    wrapper.closeDocument();
    wrapper.dispose();
    print('end: ${stopwatch.elapsed}');
  }
}
