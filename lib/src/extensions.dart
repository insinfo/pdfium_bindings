import 'package:pdfium_bindings/pdfium_bindings.dart';

extension LastError on PDFiumBindings {
  String getLastErrorMessage() {
    switch (FPDF_GetLastError()) {
      case FPDF_ERR_SUCCESS:
        return 'Success';

      case FPDF_ERR_UNKNOWN:
        return 'Unknown error';

      case FPDF_ERR_FILE:
        return 'File not found or could not be opened';

      case FPDF_ERR_FORMAT:
        return 'File not in PDF format or corrupted';

      case FPDF_ERR_PASSWORD:
        return 'Password required or incorrect password';

      case FPDF_ERR_SECURITY:
        return 'Unsupported security scheme';

      case FPDF_ERR_PAGE:
        return 'Page not found or content error';

      default:
        return 'Unknown error ';
    }
  }
}
