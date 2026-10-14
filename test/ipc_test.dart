import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:badi/platform/ipc.dart';
import 'package:badi/core/session.dart';
import 'package:badi/shell/shell_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// Binds a raw server socket on a temp path; caller owns closing it.
Future<(ServerSocket, String)> tempServer() async {
  final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
  final path = '${dir.path}/badi.sock';
  final server = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  addTearDown(() async {
    await server.close();
    await dir.delete(recursive: true);
  });
  return (server, path);
}

Future<Socket> connectTo(String path) => Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );

void main() {
  group('socket path', () {
    test('prefers XDG_RUNTIME_DIR', () {
      expect(
        ipcSocketPath({'XDG_RUNTIME_DIR': '/run/user/1000'}),
        '/run/user/1000/badi.sock',
      );
    });

    test('falls back to per-user tmp', () {
      expect(ipcSocketPath({'USER': 'ada'}), '/tmp/badi-ada.sock');
      expect(ipcSocketPath({}), '/tmp/badi-unknown.sock');
    });
  });

  group('codec', () {
    test('round-trips every message', () {
      final messages = [
        encodeOpenApps(),
        encodeOpenLines(),
        encodeLine('héllo wörld\nno-newline-in-line'),
        encodeEof(),
        encodeAck(),
        encodeResult('picked line'),
        encodeCancelled(),
        encodeError('launcher is already open'),
      ];
      final decoded = [for (final m in messages) decodeIpcMessage(jsonDecode(m))];
      expect(decoded[0], isA<OpenRequest>().having((m) => m.mode, 'mode', 'apps'));
      expect(decoded[1], isA<OpenRequest>().having((m) => m.mode, 'mode', 'lines'));
      expect(decoded[2], isA<InputLine>().having((m) => m.data, 'data', 'héllo wörld\nno-newline-in-line'));
      expect(decoded[3], isA<InputEof>());
      expect(decoded[4], isA<Ack>());
      expect(decoded[5], isA<PickResult>().having((m) => m.data, 'data', 'picked line'));
      expect(decoded[6], isA<PickCancelled>());
      expect(decoded[7], isA<RemoteError>().having((m) => m.message, 'message', 'launcher is already open'));
    });

    test('rejects version skew and bad shapes', () {
      expect(() => decodeIpcMessage(jsonDecode('{"v":999,"type":"ack"}')),
          throwsFormatException);
      expect(() => decodeIpcMessage(jsonDecode('{"v":1,"type":"nope"}')),
          throwsFormatException);
      expect(() => decodeIpcMessage(jsonDecode('{"v":1,"type":"open","mode":"x"}')),
          throwsFormatException);
      expect(() => decodeIpcMessage(jsonDecode('{"v":1,"type":"line"}')),
          throwsFormatException);
      expect(() => decodeIpcMessage(jsonDecode('[1,2]')), throwsFormatException);
      expect(() => decodeIpcMessage('ack'), throwsFormatException);
    });
  });

  group('client', () {
    test('no daemon returns null', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      expect(
        await tryOpenViaDaemon(
          socketPath: '${dir.path}/nothing.sock',
          piped: null,
        ),
        isNull,
      );
    });

    test('apps mode exits on ack', () async {
      final (server, path) = await tempServer();
      server.listen((client) async {
        final first = await socketLines(client).first;
        expect(decodeIpcMessage(jsonDecode(first)), isA<OpenRequest>());
        client.writeln(encodeAck());
        await client.flush();
        await client.close();
      });
      final outcome = await tryOpenViaDaemon(socketPath: path, piped: null);
      expect(outcome, isNotNull);
      expect(outcome!.exitCode, 0);
      expect(outcome.resultLine, isNull);
    });

    test('apps mode surfaces daemon errors', () async {
      final (server, path) = await tempServer();
      server.listen((client) async {
        await socketLines(client).first;
        client.writeln(encodeError('launcher is already open'));
        await client.flush();
        await client.close();
      });
      final outcome = await tryOpenViaDaemon(socketPath: path, piped: null);
      expect(outcome!.exitCode, 1);
      expect(outcome.error, 'launcher is already open');
    });

    test('lines mode forwards stdin and returns the pick', () async {
      final (server, path) = await tempServer();
      final seen = <String>[];
      server.listen((client) async {
        final incoming = socketLines(client);
        final it = StreamIterator(incoming);
        await it.moveNext(); // open
        client.writeln(encodeAck());
        await client.flush();
        while (await it.moveNext()) {
          final m = decodeIpcMessage(jsonDecode(it.current));
          if (m is InputLine) {
            seen.add(m.data);
          } else {
            break; // eof
          }
        }
        client.writeln(encodeResult('picked!'));
        await client.flush();
        await client.close();
      });
      final outcome = await tryOpenViaDaemon(
        socketPath: path,
        piped: Stream.fromIterable(['alpha', 'beta']),
      );
      expect(outcome!.exitCode, 0);
      expect(outcome.resultLine, 'picked!');
      expect(seen, ['alpha', 'beta']);
    });

    test('lines mode cancel exits 1 with no result', () async {
      final (server, path) = await tempServer();
      server.listen((client) async {
        final it = StreamIterator(socketLines(client));
        await it.moveNext(); // open
        client.writeln(encodeAck());
        await client.flush();
        while (await it.moveNext()) {
          if (decodeIpcMessage(jsonDecode(it.current)) is InputEof) break;
        }
        client.writeln(encodeCancelled());
        await client.flush();
        await client.close();
      });
      final outcome = await tryOpenViaDaemon(
        socketPath: path,
        piped: Stream.fromIterable(['x']),
      );
      expect(outcome!.exitCode, 1);
      expect(outcome.resultLine, isNull);
    });
  });

  group('server', () {
    test('apps open acks then closes on cancel', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final client = await connectTo('${dir.path}/badi.sock');
      addTearDown(client.close);
      client.writeln(encodeOpenApps());
      await client.flush();
      final it = StreamIterator(socketLines(client));
      await it.moveNext();
      expect(decodeIpcMessage(jsonDecode(it.current)), isA<Ack>());
      await it.cancel();

      expect(shell.launcherOpen, isTrue);
      expect(shell.mode, ShellRequestMode.apps);
      shell.currentActions!.cancel(pipeMode: false);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(shell.launcherOpen, isFalse);
    });

    test('second open while busy gets an error', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final first = await connectTo('${dir.path}/badi.sock');
      addTearDown(first.close);
      first.writeln(encodeOpenApps());
      await first.flush();
      final firstIt = StreamIterator(socketLines(first));
      await firstIt.moveNext();
      expect(decodeIpcMessage(jsonDecode(firstIt.current)), isA<Ack>());
      await firstIt.cancel();

      final second = await connectTo('${dir.path}/badi.sock');
      addTearDown(second.close);
      second.writeln(encodeOpenApps());
      await second.flush();
      final secondIt = StreamIterator(socketLines(second));
      await secondIt.moveNext();
      final reply = decodeIpcMessage(jsonDecode(secondIt.current));
      expect(reply, isA<RemoteError>());
      await secondIt.cancel();
      expect(shell.launcherOpen, isTrue); // first request still owns it
    });

    test('lines open streams input and answers the pick', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final client = await connectTo('${dir.path}/badi.sock');
      addTearDown(client.close);
      client.writeln(encodeOpenLines());
      await client.flush();
      final it = StreamIterator(socketLines(client));
      await it.moveNext();
      expect(decodeIpcMessage(jsonDecode(it.current)), isA<Ack>());

      final received = <String>[];
      final sub = shell.piped!.listen(received.add);
      client.writeln(encodeLine('hello'));
      client.writeln(encodeLine('world'));
      client.writeln(encodeEof());
      await client.flush();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, ['hello', 'world']);

      await shell.currentActions!.completeWithLine('hello');
      await it.moveNext();
      final answer = decodeIpcMessage(jsonDecode(it.current));
      expect(
        answer,
        isA<PickResult>().having((m) => m.data, 'data', 'hello'),
      );
      await it.cancel();
      await sub.cancel();
      expect(shell.launcherOpen, isFalse);
    });

    test('lines cancel answers cancelled', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final client = await connectTo('${dir.path}/badi.sock');
      addTearDown(client.close);
      client.writeln(encodeOpenLines());
      await client.flush();
      final it = StreamIterator(socketLines(client));
      await it.moveNext(); // ack
      client.writeln(encodeEof());
      await client.flush();

      shell.currentActions!.cancel(pipeMode: true);
      await it.moveNext();
      expect(decodeIpcMessage(jsonDecode(it.current)), isA<PickCancelled>());
      await it.cancel();
      expect(shell.launcherOpen, isFalse);
    });

    test('full round trip: real client through real server', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final outcomeFuture = tryOpenViaDaemon(
        socketPath: '${dir.path}/badi.sock',
        piped: Stream.fromIterable(['a', 'b']),
      );
      // Wait for the daemon side to open (bounded poll).
      for (var i = 0; i < 200 && !shell.launcherOpen; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(shell.launcherOpen, isTrue);
      await shell.currentActions!.completeWithLine('b');

      final outcome = await outcomeFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(outcome, isNotNull);
      expect(outcome!.exitCode, 0);
      expect(outcome.resultLine, 'b');
      expect(shell.launcherOpen, isFalse);
    });

    test('empty pipe falls back to apps, client gets cancel', () async {
      final dir = await Directory.systemTemp.createTemp('badi-ipc-test');
      addTearDown(() => dir.delete(recursive: true));
      final shell = ShellController();
      addTearDown(shell.dispose);
      final server = await serveIpc(shell, '${dir.path}/badi.sock');
      addTearDown(server.close);

      final outcomeFuture = tryOpenViaDaemon(
        socketPath: '${dir.path}/badi.sock',
        // Immediate EOF, zero lines: daemon shows apps instead.
        piped: const Stream.empty(),
      );
      for (var i = 0; i < 200 && !shell.launcherOpen; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(shell.launcherOpen, isTrue);
      // The human launches an app (harmless `/bin/true`); the lines client
      // asked for a line, so it gets a cancel.
      await shell.currentActions!.completeWithApp(
        const LaunchTarget(argv: ['true'], terminal: false),
      );

      final outcome = await outcomeFuture.timeout(
        const Duration(seconds: 10),
      );
      expect(outcome!.exitCode, 1);
      expect(outcome.resultLine, isNull);
      expect(shell.launcherOpen, isFalse);
    });
  });
}
