class PdfiumException implements Exception {
  int? errorCode;
  String? message = '';
  PdfiumException({this.message});

  factory PdfiumException.fromErrorCode(int errorCode) {
    var e = FileException();
    e.errorCode = errorCode;
    return e;
  }

  @override
  String toString() {
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
