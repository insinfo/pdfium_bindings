/// An exception class that's thrown when a pdfium operation is unable to be
/// done correctly.
class PdfiumException implements Exception {
  /// Error code of the exception
  int? errorCode;

  /// A message describing the error.
  String?
      message; // Removido '= ''', pois é desnecessário para um tipo anulável

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
  UnknownException({super.message});
}

class FileException extends PdfiumException {
  FileException({super.message});
}

class FormatException extends PdfiumException {
  FormatException({super.message});
}

class PasswordException extends PdfiumException {
  PasswordException({super.message});
}

class SecurityException extends PdfiumException {
  SecurityException({super.message});
}

class PageException extends PdfiumException {
  PageException({super.message});
}

/// Thrown when the native pdfium dynamic library cannot be located.
class MissingLibraryException extends PdfiumException {
  MissingLibraryException({required String path})
      : super(message: 'Unable to locate PDFium library at $path');
}

/// Thrown when rendering a page fails.
class PageRenderException extends PageException {
  PageRenderException({
    super.message,
    this.pageIndex,
    required this.width,
    required this.height,
    required this.flags,
    required this.rotate,
    this.errorDetails,
  });

  /// Zero-based index of the page being rendered, if known.
  final int? pageIndex;

  /// Width passed to the renderer.
  final int width;

  /// Height passed to the renderer.
  final int height;

  /// Flags passed to the renderer.
  final int flags;

  /// Rotation passed to the renderer.
  final int rotate;

  /// Additional diagnostic information.
  final String? errorDetails;

  @override
  String toString() {
    final buffer = StringBuffer(runtimeType)
      ..write(': ')
      ..write(message ?? 'Rendering failed');
    if (pageIndex != null) buffer.write(' | pageIndex=$pageIndex');
    buffer.write(' | size=${width}x$height');
    buffer.write(' | flags=$flags');
    buffer.write(' | rotate=$rotate');
    if (errorDetails != null && errorDetails!.isNotEmpty) {
      buffer.write(' | details=$errorDetails');
    }
    if (errorCode != null) {
      buffer.write(' | code=$errorCode');
    }
    return buffer.toString();
  }
}
