//C:\MyDartProjects\pdfium\pdfium_bindings\lib\src\pdfium_editing_bindings.dart
// ignore_for_file: camel_case_types, non_constant_identifier_names

import 'dart:ffi';

import 'package:pdfium_bindings/src/pdfium_bindings.dart';

/// Mirrors the native `FPDF_FILEWRITE` structure.
final class FPDF_FILEWRITE extends Struct {
  @Int()
  external int version;

  external Pointer<NativeFunction<WriteBlockNative>> WriteBlock;
}

typedef WriteBlockNative = Int32 Function(
  Pointer<FPDF_FILEWRITE>,
  Pointer<Void>,
  UnsignedLong,
);

class PdfiumEditingBindings {
  PdfiumEditingBindings(this._dylib);

  final DynamicLibrary _dylib;

  late final _createNewDocument =
      _dylib.lookupFunction<FPDF_DOCUMENT Function(), FPDF_DOCUMENT Function()>(
          'FPDF_CreateNewDocument');

  late final _importPages = _dylib.lookupFunction<
      Int32 Function(
        FPDF_DOCUMENT,
        FPDF_DOCUMENT,
        FPDF_BYTESTRING,
        Int32,
      ),
      int Function(
        FPDF_DOCUMENT,
        FPDF_DOCUMENT,
        FPDF_BYTESTRING,
        int,
      )>('FPDF_ImportPages');

  late final _saveAsCopy = _dylib.lookupFunction<
      Int32 Function(
        FPDF_DOCUMENT,
        Pointer<FPDF_FILEWRITE>,
        FPDF_DWORD,
      ),
      int Function(
        FPDF_DOCUMENT,
        Pointer<FPDF_FILEWRITE>,
        int,
      )>('FPDF_SaveAsCopy');

  late final _copyViewerPreferences = _dylib.lookupFunction<
      Int32 Function(FPDF_DOCUMENT, FPDF_DOCUMENT),
      int Function(FPDF_DOCUMENT, FPDF_DOCUMENT)>(
    'FPDF_CopyViewerPreferences',
  );

  FPDF_DOCUMENT createNewDocument() => _createNewDocument();

  bool importPages(
    FPDF_DOCUMENT dest,
    FPDF_DOCUMENT src,
    FPDF_BYTESTRING range,
    int insertAt,
  ) =>
      _importPages(dest, src, range, insertAt) != 0;

  bool saveAsCopy(
    FPDF_DOCUMENT document,
    Pointer<FPDF_FILEWRITE> writer,
    int flags,
  ) =>
      _saveAsCopy(document, writer, flags) != 0;

  void copyViewerPreferences(FPDF_DOCUMENT dest, FPDF_DOCUMENT src) {
    _copyViewerPreferences(dest, src);
  }
}
