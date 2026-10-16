import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Raw Sway/i3 IPC framing.
///
/// Every message is: magic `"i3-ipc"` (6 bytes) + payload length (u32 LE) +
/// message type (u32 LE) + UTF-8 JSON payload. Replies echo the request type;
/// events set the high bit (`type | 0x80000000`).
class SwayIpc {
  SwayIpc._();

  static const magic = 'i3-ipc';
  static const headerLength = 14;

  // Request types (shared i3 subset; stable on Sway).
  static const runCommand = 0;
  static const getWorkspaces = 1;
  static const subscribe = 2;
  static const getVersion = 7;

  static const eventMask = 0x80000000;

  /// Encodes one request frame.
  static Uint8List encode(int type, [String payload = '']) {
    final body = utf8.encode(payload);
    final out = BytesBuilder();
    out.add(utf8.encode(magic));
    final header = ByteData(8)..setUint32(0, body.length, Endian.little);
    header.setUint32(4, type, Endian.little);
    out.add(header.buffer.asUint8List());
    out.add(body);
    return out.toBytes();
  }

  /// Tries one header parse. Returns null when [bytes] holds no full frame
  /// yet; otherwise the `(type, payload, consumedBytes)` triple.
  static (int, String, int)? tryDecode(List<int> bytes) {
    if (bytes.length < headerLength) return null;
    if (ascii.decode(bytes.sublist(0, 6)) != magic) {
      throw const FormatException('bad sway ipc magic');
    }
    final view = Uint8List.fromList(bytes);
    final data = ByteData.sublistView(view);
    final length = data.getUint32(6, Endian.little);
    final type = data.getUint32(10, Endian.little);
    if (bytes.length < headerLength + length) return null;
    final payload =
        utf8.decode(bytes.sublist(headerLength, headerLength + length));
    return (type, payload, headerLength + length);
  }
}

/// Discovers the Sway socket. `[env]` is injectable for tests; defaults to
/// the real process environment.
String? swaySocketPath([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  for (final key in ['SWAYSOCK', 'I3SOCK']) {
    final v = e[key];
    if (v != null && v.isNotEmpty) return v;
  }
  return null;
}

/// One-shot request: connect, send, read exactly one reply frame, close.
///
/// Throws [SocketException] when the compositor is unreachable and
/// [TimeoutException] on timeout; callers map those to "unavailable".
Future<String> swayRequest(
  String socketPath,
  int type, [
  String payload = '',
  Duration timeout = const Duration(seconds: 2),
]) async {
  final socket = await Socket.connect(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  ).timeout(timeout);
  try {
    socket.add(SwayIpc.encode(type, payload));
    await socket.flush();
    final buf = <int>[];
    final completer = Completer<String>();
    late final StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (chunk) {
        buf.addAll(chunk);
        final decoded = SwayIpc.tryDecode(buf);
        if (decoded != null && !completer.isCompleted) {
          completer.complete(decoded.$2);
          sub.cancel();
        }
      },
      onError: (Object e) {
        if (!completer.isCompleted) completer.completeError(e);
      },
      onDone: () {
        if (!completer.isCompleted) {
          completer.completeError(
            const FormatException('sway closed connection early'),
          );
        }
      },
      cancelOnError: true,
    );
    return await completer.future.timeout(timeout);
  } finally {
    try {
      await socket.close();
    } catch (_) {}
    socket.destroy();
  }
}
