import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../shell/shell_actions.dart';
import '../shell/shell_controller.dart';

/// Single-instance IPC between the long-lived shell (`badi --shell`) and
/// short-lived open commands (bare `badi`, optionally with piped stdin).
///
/// Transport: newline-delimited JSON over a Unix domain socket. The client
/// connects, sends one `open` request, then (lines mode only) streams input
/// lines and waits for the pick. The daemon replies `ack` immediately so an
/// apps-mode client can exit, and later answers a lines-mode client with
/// exactly one of `result` / `cancelled` / `error`.
///
/// The Zig core is deliberately uninvolved: it only filters rows. All of
/// this is process plumbing and lives in Dart.
const ipcVersion = 1;

/// Well-known socket path: `$XDG_RUNTIME_DIR/badi.sock`, falling back to a
/// per-user file under `/tmp` (e.g. SSH sessions without a runtime dir).
/// [environment] is injectable for tests; defaults to the real one.
String ipcSocketPath([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final runtime = env['XDG_RUNTIME_DIR'];
  if (runtime != null && runtime.isNotEmpty) return '$runtime/badi.sock';
  final user = env['USER'] ?? env['LOGNAME'] ?? 'unknown';
  return '/tmp/badi-$user.sock';
}

// ------------------------------------------------------------------- codec

String encodeOpenApps() =>
    jsonEncode({'v': ipcVersion, 'type': 'open', 'mode': 'apps'});

String encodeOpenLines() =>
    jsonEncode({'v': ipcVersion, 'type': 'open', 'mode': 'lines'});

String encodeLine(String line) =>
    jsonEncode({'v': ipcVersion, 'type': 'line', 'data': line});

String encodeBatch(List<String> lines) =>
    jsonEncode({'v': ipcVersion, 'type': 'batch', 'data': lines});

String encodeEof() => jsonEncode({'v': ipcVersion, 'type': 'eof'});

String encodeAck() => jsonEncode({'v': ipcVersion, 'type': 'ack'});

String encodeResult(String line) =>
    jsonEncode({'v': ipcVersion, 'type': 'result', 'data': line});

String encodeCancelled() => jsonEncode({'v': ipcVersion, 'type': 'cancelled'});

String encodeError(String message) =>
    jsonEncode({'v': ipcVersion, 'type': 'error', 'message': message});

/// One parsed protocol message. Client->daemon: [OpenRequest], [InputLine],
/// [InputEof]. Daemon->client: [Ack], [PickResult], [PickCancelled],
/// [RemoteError].
sealed class IpcMessage {
  const IpcMessage();
}

class OpenRequest extends IpcMessage {
  const OpenRequest(this.mode);
  final String mode; // 'apps' or 'lines'
}

class InputLine extends IpcMessage {
  const InputLine(this.data);
  final String data;
}

class InputBatch extends IpcMessage {
  const InputBatch(this.lines);
  final List<String> lines;
}

class InputEof extends IpcMessage {
  const InputEof();
}

class Ack extends IpcMessage {
  const Ack();
}

class PickResult extends IpcMessage {
  const PickResult(this.data);
  final String data;
}

class PickCancelled extends IpcMessage {
  const PickCancelled();
}

class RemoteError extends IpcMessage {
  const RemoteError(this.message);
  final String message;
}

/// Parses one decoded JSON line. Throws [FormatException] on anything
/// unexpected (wrong version, shape, or type), so version skew between a
/// stale client and a new daemon fails loudly instead of hanging.
IpcMessage decodeIpcMessage(Object? json) {
  if (json is! Map) throw FormatException('not an object: $json');
  if (json['v'] != ipcVersion) {
    throw FormatException('unsupported protocol v${json['v']}');
  }
  switch (json['type']) {
    case 'open':
      final mode = json['mode'];
      if (mode != 'apps' && mode != 'lines') {
        throw FormatException('bad open mode: $mode');
      }
      return OpenRequest(mode as String);
    case 'line':
      final data = json['data'];
      if (data is! String) throw FormatException('bad line data: $data');
      return InputLine(data);
    case 'batch':
      final data = json['data'];
      if (data is! List || data.any((line) => line is! String)) {
        throw FormatException('bad batch data: $data');
      }
      return InputBatch(List<String>.unmodifiable(data.cast<String>()));
    case 'eof':
      return const InputEof();
    case 'ack':
      return const Ack();
    case 'result':
      final data = json['data'];
      if (data is! String) throw FormatException('bad result data: $data');
      return PickResult(data);
    case 'cancelled':
      return const PickCancelled();
    case 'error':
      final message = json['message'];
      if (message is! String) {
        throw FormatException('bad error message: $message');
      }
      return RemoteError(message);
    default:
      throw FormatException('unknown type: ${json['type']}');
  }
}

/// Decoded JSON lines arriving on [socket]. The socket stays open; callers
/// own closing it.
Stream<String> socketLines(Socket socket) =>
    const LineSplitter().bind(const Utf8Decoder().bind(socket));

// ------------------------------------------------------------------ client

/// Outcome of asking the daemon to open the launcher. [resultLine] is set
/// for a lines-mode pick (print it to stdout); [error] is a human message
/// for stderr. Either way the process should `exit(exitCode)` after flushing.
class ClientOutcome {
  const ClientOutcome({required this.exitCode, this.resultLine, this.error});

  final int exitCode;
  final String? resultLine;
  final String? error;
}

/// Asks a running daemon to open the launcher.
///
/// [piped] is null for apps mode (keybinding, bar click equivalent), or the
/// stdin line stream for dmenu mode (`find / | badi`): lines are forwarded
/// as they arrive and the pick is returned in [ClientOutcome.resultLine].
///
/// Returns null when no daemon is listening: the caller falls back (daemon
/// mode under `--shell`, or a one-shot window otherwise). Never touches
/// Flutter, so keypress clients stay fast.
Future<ClientOutcome?> tryOpenViaDaemon({
  required String socketPath,
  required Stream<dynamic>? piped,
  Duration connectTimeout = const Duration(seconds: 2),
}) async {
  late final Socket sock;
  try {
    sock = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
    ).timeout(connectTimeout);
  } on SocketException {
    return null; // no daemon (missing or stale socket file)
  } on TimeoutException {
    return null;
  }
  try {
    if (piped == null) return await _appsExchange(sock);
    return await _linesExchange(sock, piped);
  } catch (e) {
    return ClientOutcome(exitCode: 1, error: '$e');
  } finally {
    try {
      await sock.close();
    } catch (_) {}
  }
}

/// Apps mode: open, wait for ack, leave. The daemon owns spawning.
Future<ClientOutcome> _appsExchange(Socket sock) async {
  sock.writeln(encodeOpenApps());
  await sock.flush();
  final it = StreamIterator(socketLines(sock));
  try {
    if (!await it.moveNext().timeout(const Duration(seconds: 10))) {
      return const ClientOutcome(
        exitCode: 1,
        error: 'daemon closed the connection',
      );
    }
    return switch (decodeIpcMessage(jsonDecode(it.current))) {
      Ack() => const ClientOutcome(exitCode: 0),
      RemoteError(:final message) => ClientOutcome(exitCode: 1, error: message),
      _ => const ClientOutcome(exitCode: 1, error: 'unexpected daemon reply'),
    };
  } finally {
    await it.cancel();
  }
}

/// Lines mode: open, stream stdin concurrently, wait for the pick.
/// The pick wait is unbounded: the user may take as long as they like.
Future<ClientOutcome> _linesExchange(
  Socket sock,
  Stream<dynamic> piped,
) async {
  sock.writeln(encodeOpenLines());
  await sock.flush();
  final forwarding = _forwardInput(sock, piped);
  final it = StreamIterator(socketLines(sock));
  try {
    if (!await it.moveNext().timeout(const Duration(seconds: 10))) {
      return const ClientOutcome(
        exitCode: 1,
        error: 'daemon closed the connection',
      );
    }
    final first = decodeIpcMessage(jsonDecode(it.current));
    if (first is! Ack) {
      if (first is RemoteError) {
        return ClientOutcome(exitCode: 1, error: first.message);
      }
      return const ClientOutcome(exitCode: 1, error: 'unexpected daemon reply');
    }
    if (!await it.moveNext()) {
      return const ClientOutcome(
        exitCode: 1,
        error: 'daemon went away before answering',
      );
    }
    return switch (decodeIpcMessage(jsonDecode(it.current))) {
      PickResult(:final data) => ClientOutcome(exitCode: 0, resultLine: data),
      PickCancelled() => const ClientOutcome(exitCode: 1),
      RemoteError(:final message) => ClientOutcome(exitCode: 1, error: message),
      _ => const ClientOutcome(exitCode: 1, error: 'unexpected daemon reply'),
    };
  } finally {
    await it.cancel();
    // The daemon closes its side after answering, which ends forwarding
    // via a write error; bound the wait so a wedged stdin can't hang exit.
    try {
      await forwarding.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }
}

/// Pumps stdin lines to the daemon, then an `eof`. Ends early (via a write
/// error) when the daemon answers and closes its side first.
Future<void> _forwardInput(Socket sock, Stream<dynamic> piped) async {
  try {
    await for (final event in piped) {
      if (event is String) {
        sock.writeln(encodeLine(event));
      } else {
        sock.writeln(encodeBatch(event as List<String>));
      }
      await sock.flush();
    }
    sock.writeln(encodeEof());
    await sock.flush();
  } catch (_) {
    // Socket gone (daemon answered already) or stdin errored: the reply
    // wait decides the outcome, nothing useful to report here.
  }
}

// ------------------------------------------------------------------ server

/// Serves open-requests into [shell]. Awaits the bind so daemon startup can
/// report failures; the returned socket lives for the process lifetime.
///
/// A leftover file from a crashed daemon is removed first. A bind failure
/// therefore means a live daemon holds the path: the caller should exit.
Future<ServerSocket> serveIpc(ShellController shell, String socketPath) async {
  final file = File(socketPath);
  if (await file.exists()) {
    try {
      await file.delete();
    } catch (_) {}
  }
  final server = await ServerSocket.bind(
    InternetAddress(socketPath, type: InternetAddressType.unix),
    0,
  );
  server.listen((client) {
    unawaited(_handleConnection(client, shell));
  });
  return server;
}

/// One client connection: parse the open request, show the launcher, pump
/// input lines (lines mode), and answer the client on pick/cancel.
Future<void> _handleConnection(Socket client, ShellController shell) async {
  Future<void> send(String message) async {
    client.writeln(message);
    await client.flush();
  }

  Future<void> fail(String message) async {
    try {
      await send(encodeError(message));
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
  }

  try {
    final it = StreamIterator(socketLines(client));
    bool open;
    try {
      if (!await it.moveNext().timeout(const Duration(seconds: 10))) {
        try {
          await client.close();
        } catch (_) {}
        return;
      }
    } on TimeoutException {
      try {
        await client.close();
      } catch (_) {}
      return;
    }
    final first = decodeIpcMessage(jsonDecode(it.current));
    if (first is! OpenRequest) {
      await fail('first message must be an open request');
      return;
    }
    if (first.mode == 'apps') {
      await it.cancel();
      open = shell.openApps(
        actions: ShellAppActions(onDone: shell.closeLauncher),
      );
      if (!open) {
        await fail('launcher is already open');
        return;
      }
      // Fire-and-forget: the apps client leaves on ack; the daemon owns
      // spawning and closing from here.
      await send(encodeAck());
      try {
        await client.close();
      } catch (_) {}
      return;
    }

    // Lines mode: the client stays for the answer.
    var answered = false;
    final actions = ShellPipeActions(
      replyResult: (line) async {
        answered = true;
        await send(encodeResult(line));
        try {
          await client.close();
        } catch (_) {}
      },
      replyCancelled: () async {
        answered = true;
        await send(encodeCancelled());
        try {
          await client.close();
        } catch (_) {}
      },
      onDone: shell.closeLauncher,
    );
    open = shell.openLines(actions: actions);
    if (!open) {
      await it.cancel();
      await fail('launcher is already open');
      return;
    }
    await send(encodeAck());
    var sawEof = false;
    try {
      while (await it.moveNext()) {
        final message = decodeIpcMessage(jsonDecode(it.current));
        switch (message) {
          case InputLine(:final data):
            shell.appendLine(data);
          case InputBatch(:final lines):
            shell.appendLines(lines);
          case InputEof():
            sawEof = true;
          case _:
            throw FormatException('unexpected message: ${it.current}');
        }
        if (sawEof) break;
      }
    } catch (_) {
      if (!answered) await fail('bad input stream');
      shell.closeLauncher();
      return;
    } finally {
      await it.cancel();
    }
    shell.closeInput();
    if (!sawEof && !answered) {
      // Client vanished mid-pick (killed): don't leave a stuck picker.
      shell.closeLauncher();
    }
  } catch (_) {
    try {
      await client.close();
    } catch (_) {}
  }
}
