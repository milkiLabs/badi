import 'dart:convert';

/// Internal representation for a piped row with different display and result
/// values. Ordinary rows remain unchanged.
// Keep this non-NUL: rows cross the native picker boundary as C strings.
const _rowPrefix = '\u{10FFFF}badi-piped-row:';

String encodePipedRow(String display, String source) =>
    '$_rowPrefix${jsonEncode([display, source])}';

String pipedRowTitle(String value) => _decode(value)?.$1 ?? value;

String pipedRowResult(String value) => _decode(value)?.$2 ?? value;

(String, String)? _decode(String value) {
  if (!value.startsWith(_rowPrefix)) return null;
  try {
    final decoded = jsonDecode(value.substring(_rowPrefix.length));
    if (decoded is List &&
        decoded.length == 2 &&
        decoded[0] is String &&
        decoded[1] is String) {
      return (decoded[0] as String, decoded[1] as String);
    }
  } on FormatException {
    // Keep malformed or unrelated input intact.
  }
  return null;
}
