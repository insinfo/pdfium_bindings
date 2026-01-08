import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:pdfium_bindings/pdfium_bindings.dart';

main() {
  final config = PdfiumConfig(
      libraryPath: r'C:\MyDartProjects\pdfium\pdfium_bindings\pdfium.dll');
  final wrapper = PdfiumWrap(config: config);

  final inputPath =
      r'C:\MyDartProjects\new_sali\backend\test\assets\sample_govbr_signature_assinado.pdf';
  wrapper.loadDocumentFromPath(inputPath);
  final pageCount = wrapper.getPageCount();
  for (var i = 0; i < pageCount; i++) {
    wrapper.loadPage(i);
    final image = wrapper.renderPageToImage(
      scale: 1,
      renderFormFields: true,
    );
    final outPath = p.join(
      Directory.current.path,
      'test',
      'assets',
      'sample_govbr_signature_assinado_page_${i + 1}.png',
    );
    File(outPath).writeAsBytesSync(img.encodePng(image, level: 6), flush: true);
    wrapper.closePage();
  }
  wrapper.closeDocument();
}
