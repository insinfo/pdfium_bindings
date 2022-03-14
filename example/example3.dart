import 'package:pdfium_bindings/pdfium_bindings.dart';
import 'package:http/http.dart' as http;

void main() async {
  var pdfium = PdfiumWrap();

  var resp = await http.get(Uri.parse(
      'https://www.riodasostras.rj.gov.br/wp-content/uploads/2022/03/1426.pdf'));
  var bytes = resp.bodyBytes;

  pdfium
      .loadDocumentFromBytes(bytes)
      .loadPage(0)
      .savePageAsJpg('out.jpg', qualityJpg: 80)
      .closePage()
      .closeDocument()
      .dispose();
}
