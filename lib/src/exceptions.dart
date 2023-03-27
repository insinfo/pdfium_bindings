/// An exception class that's thrown when a pdfium operation is unable to be
/// done correctly.
class PdfiumException implements Exception {
  /// Error code of the exception
  int? errorCode;

  /// A message describing the error.
  String? message = '';

  /// Default constructor of PdfiumException
  PdfiumException({this.message});

  /// Factory constructor to create a FileException with an error code
  factory PdfiumException.fromErrorCode(int errorCode) {
    final e = FileException();
    e.errorCode = errorCode;
    return e;
  }

  @override
  String toString() {
    // ignore: no_runtimetype_tostring
    return '$runtimeType: $errorCode | $message';
  }
}

class UnknownException extends PdfiumException {
  UnknownException({String? message}) : super(message: message);
}

class FileException extends PdfiumException {
  FileException({String? message}) : super(message: message);
}

class FormatException extends PdfiumException {
  FormatException({String? message}) : super(message: message);
}

class PasswordException extends PdfiumException {
  PasswordException({String? message}) : super(message: message);
}

class SecurityException extends PdfiumException {
  SecurityException({String? message}) : super(message: message);
}

class PageException extends PdfiumException {
  PageException({String? message}) : super(message: message);
}
