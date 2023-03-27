import 'package:http/http.dart' as http;
import 'package:pdfium_bindings/pdfium_bindings.dart';

void main() async {
  final pdfium = PdfiumWrap();

  final resp = await http.get(
    Uri.parse(
      'https://www.riodasostras.rj.gov.br/wp-content/uploads/2022/03/1426.pdf',
    ),
  );
  final bytes = resp.bodyBytes;

  pdfium
      .loadDocumentFromBytes(bytes)
      .loadPage(0)
      .savePageAsJpg('out.jpg', qualityJpg: 80)
      .closePage()
      .closeDocument()
      .dispose();
}
