import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

Pointer<Void> stringToNativeVoid(String str, {Allocator allocator = calloc}) {
  final units = utf8.encode(str);
  final result = allocator<Uint8>(units.length + 1);
  final nativeString = result.asTypedList(units.length + 1);
  nativeString.setAll(0, units);
  nativeString[units.length] = 0;
  return result.cast();
}

Pointer<Utf8> stringToNativeChar(String str, {Allocator allocator = calloc}) {
  final units = utf8.encode(str);
  final result = allocator<Uint8>(units.length + 1);
  final nativeString = result.asTypedList(units.length + 1);
  nativeString.setAll(0, units);
  nativeString[units.length] = 0;
  return result.cast();
}

Pointer<Int8> stringToNativeInt8(String str, {Allocator allocator = calloc}) {
  final units = utf8.encode(str);
  final result = allocator<Uint8>(units.length + 1);
  final nativeString = result.asTypedList(units.length + 1);
  nativeString.setAll(0, units);
  nativeString[units.length] = 0;
  return result.cast();
}

String nativeInt8ToString(Pointer<Int8> pointer, {bool allowMalformed = true}) {
  final ptrName = pointer.cast<Utf8>();
  final ptrNameCodeUnits = pointer.cast<Uint8>();
  final list = ptrNameCodeUnits.asTypedList(ptrName.length);
  return utf8.decode(list, allowMalformed: allowMalformed);
}

Uint8List nativeInt8ToCodeUnits(Pointer<Int8> pointer) {
  final ptrName = pointer.cast<Utf8>();
  final ptrNameCodeUnits = pointer.cast<Uint8>();
  final list = ptrNameCodeUnits.asTypedList(ptrName.length);
  return list;
}

Uint8List nativeInt8ToUint8List(Pointer<Int8> pointer) {
  final ptrName = pointer.cast<Utf8>();
  final ptrNameCodeUnits = pointer.cast<Uint8>();
  final list = ptrNameCodeUnits.asTypedList(ptrName.length);
  return list;
}

/// Sanitize-filename removes the following:
/// Control characters (0x00–0x1f and 0x80–0x9f)
/// Reserved characters (/, ?, <, >, \, :, *, |, and ")
/// Unix reserved filenames (. and ..)
/// Trailing periods and spaces (for Windows)
/// Windows reserved filenames (CON, PRN, AUX, NUL, COM1, COM2, COM3, COM4, COM5, COM6, COM7, COM8, COM9, LPT1, LPT2, LPT3, LPT4, LPT5, LPT6, LPT7, LPT8, and LPT9)
String sanitizeFilename(String input, [String replacement = '_']) {
  final illegalRe = RegExp(r'[\/\?<>\\:\*\|"]', multiLine: true);
  final controlRe = RegExp(r'[\x00-\x1f\x80-\x9f]', multiLine: true);
  final reservedRe = RegExp(r'^\.+$');
  final windowsReservedRe = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$',
    caseSensitive: false,
  );
  // var windowsTrailingRe = RegExp(r'[\. ]+$');

  var sanitized = input
      .replaceAll('�', replacement)
      .replaceAll('А╟', replacement)
      .replaceAll('╟', replacement)
      .replaceAll(illegalRe, replacement)
      .replaceAll(controlRe, replacement)
      .replaceAll(reservedRe, replacement);
  //  .replaceAll(windowsReservedRe, replacement)
  // .replaceAll(windowsTrailingRe, replacement);

  if (windowsReservedRe.hasMatch(input)) {
    if (!input.contains('.')) {
      sanitized = replacement + sanitized;
    }
  }

  return sanitized;
  //return truncate(sanitized, 255);
}

bool isUft8MalformedStringPointer(Pointer<Int8> pointer) {
  try {
    final ptrName = pointer.cast<Utf8>();
    final ptrNameCodeUnits = pointer.cast<Uint8>();
    final list = ptrNameCodeUnits.asTypedList(ptrName.length);
    utf8.decode(list);
    return false;
  } catch (e) {
    return true;
  }
}

String uint8ListToString(Uint8List list, {bool allowMalformed = true}) {
  return utf8.decode(list, allowMalformed: allowMalformed);
}

Uint8List stringToUint8ListTo(String str) {
  return Uint8List.fromList(utf8.encode(str));
}

/// combine/concatenate two Uint8List
Uint8List concatenateUint8List(List<Uint8List> lists) {
  final bytesBuilder = BytesBuilder();
  for (final l in lists) {
    bytesBuilder.add(l);
  }
  return bytesBuilder.toBytes();
}

Pointer<Void> intToNativeVoid(int number) {
  final ptr = calloc.allocate<Int32>(sizeOf<Int32>());
  ptr.value = number;
  return ptr.cast();
}

Pointer<Int8> uint8ListToPointerInt8(
  Uint8List units, {
  Allocator allocator = calloc,
}) {
  final pointer = allocator<Uint8>(units.length + 1); //blob
  final nativeString = pointer.asTypedList(units.length + 1); //blobBytes
  nativeString.setAll(0, units);
  nativeString[units.length] = 0;
  return pointer.cast();
}

Future writeAndFlush(IOSink sink, Object object) {
  return sink.addStream(
    (StreamController<List<int>>(sync: true)
          ..add(utf8.encode(object.toString()))
          ..close())
        .stream,
  );
}

extension Uint8ListBlobConversion on Uint8List {
  /// Allocates a pointer filled with the Uint8List data.
  Pointer<Uint8> allocatePointer() {
    final blob = calloc<Uint8>(length);
    final blobBytes = blob.asTypedList(length);
    blobBytes.setAll(0, this);
    return blob;
  }
}

num pointsToPixels(num points, num ppi) {
  return points / 72 * ppi;
}

/*
/// [Utf8] implements conversion between Dart strings and null-terminated
/// Utf8-encoded "char*" strings in C.
///
/// [Utf8] is represented as a Struct so that `Pointer<Utf8>` can be used in
/// native function signatures.
//
// TODO(https://github.com/dart-lang/ffi/issues/4): No need to use
// 'asTypedList' when Pointer operations are performant.
class Utf8 extends Struct {
  /// Returns the length of a null-terminated string -- the number of (one-byte)
  /// characters before the first null byte.
  static int strlen(Pointer<Utf8> string) {
    final Pointer<Uint8> array = string.cast<Uint8>();
    final Uint8List nativeString = array.asTypedList(_maxSize);
    return nativeString.indexWhere((char) => char == 0);
  }

  /// Creates a [String] containing the characters UTF-8 encoded in [string].
  ///
  /// The [string] must be a zero-terminated byte sequence of valid UTF-8
  /// encodings of Unicode code points. It may also contain UTF-8 encodings of
  /// unpaired surrogate code points, which is not otherwise valid UTF-8, but
  /// which may be created when encoding a Dart string containing an unpaired
  /// surrogate. See [Utf8Decoder] for details on decoding.
  ///
  /// Returns a Dart string containing the decoded code points.
  static String fromUtf8(Pointer<Utf8> string) {
    final int length = strlen(string);
    return utf8.decode(Uint8List.view(
        string.cast<Uint8>().asTypedList(length).buffer, 0, length));
  }

  /// Convert a [String] to a Utf8-encoded null-terminated C string.
  ///
  /// If 'string' contains NULL bytes, the converted string will be truncated
  /// prematurely. Unpaired surrogate code points in [string] will be preserved
  /// in the UTF-8 encoded result. See [Utf8Encoder] for details on encoding.
  ///
  /// Returns a malloc-allocated pointer to the result.
  static Pointer<Utf8> toUtf8(String string) {
    final units = utf8.encode(string);
    final Pointer<Uint8> result = allocate<Uint8>(count: units.length + 1);
    final Uint8List nativeString = result.asTypedList(units.length + 1);
    nativeString.setAll(0, units);
    nativeString[units.length] = 0;
    return result.cast();
  }

  String toString() => fromUtf8(addressOf);
}
*/
