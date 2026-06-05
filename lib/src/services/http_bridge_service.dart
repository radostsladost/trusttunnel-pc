import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Double CRLF that terminates an HTTP header block.
const _kDoubleCrlf = [13, 10, 13, 10];

// ─────────────────────────────────────────────────────────────────────────────
// _StreamBuffer
// ─────────────────────────────────────────────────────────────────────────────

/// Byte accumulator that a [StreamSubscription] feeds into, providing async,
/// delimiter-aware read primitives without ever converting raw bytes to strings
/// prematurely.
///
/// Callers register their intent by awaiting one of the read methods; the
/// implementation re-registers a callback on every [add] until the condition
/// is satisfied, then resolves the future and removes the consumed bytes.
class _StreamBuffer {
  final _buf = <int>[];
  bool _closed = false;

  /// Live waiters; each entry re-registers itself until its condition is met.
  final _callbacks = <void Function()>[];

  // ── Feed ──────────────────────────────────────────────────────────────────

  void add(List<int> data) {
    _buf.addAll(data);
    _notifyAll();
  }

  void close() {
    _closed = true;
    _notifyAll();
  }

  void _notifyAll() {
    // Snapshot + clear first so that re-registrations from inside a callback
    // land on a fresh list and are not invoked in the current round.
    final snapshot = List<void Function()>.from(_callbacks);
    _callbacks.clear();
    for (final cb in snapshot) {
      cb();
    }
  }

  // ── Read primitives ───────────────────────────────────────────────────────

  /// Resolves with exactly [count] bytes (removed from the front of the
  /// buffer).  Throws a [StateError] if the stream closes before they arrive.
  Future<List<int>> readExact(int count) {
    final completer = Completer<List<int>>();

    void tryRead() {
      if (completer.isCompleted) return;

      if (_buf.length >= count) {
        final result = _buf.sublist(0, count);
        _buf.removeRange(0, count);
        completer.complete(result);
        return;
      }

      if (_closed) {
        completer.completeError(
          StateError(
            'Stream closed before $count bytes became available '
            '(only ${_buf.length} buffered)',
          ),
        );
        return;
      }

      _callbacks.add(tryRead);
    }

    tryRead();
    return completer.future;
  }

  /// Resolves with all bytes up to and **including** [delimiter] (removed from
  /// the front of the buffer).  Returns `null` if the stream closes before the
  /// delimiter is found.
  Future<List<int>?> readUntil(List<int> delimiter) {
    final completer = Completer<List<int>?>();

    void tryRead() {
      if (completer.isCompleted) return;

      // Linear search for the delimiter sequence.
      outer:
      for (int i = 0; i <= _buf.length - delimiter.length; i++) {
        for (int j = 0; j < delimiter.length; j++) {
          if (_buf[i + j] != delimiter[j]) continue outer;
        }
        // Found at index i.
        final result = _buf.sublist(0, i + delimiter.length);
        _buf.removeRange(0, i + delimiter.length);
        completer.complete(result);
        return;
      }

      if (_closed) {
        completer.complete(null);
        return;
      }

      _callbacks.add(tryRead);
    }

    tryRead();
    return completer.future;
  }

  /// Returns all buffered bytes and clears the buffer.
  List<int> drain() {
    final result = List<int>.from(_buf);
    _buf.clear();
    return result;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HttpBridgeService
// ─────────────────────────────────────────────────────────────────────────────

/// A pure-Dart HTTP CONNECT → SOCKS5 bridge that listens on `127.0.0.1` on a
/// dynamically-assigned port.
///
/// Both `CONNECT` tunnels (HTTPS) and plain `GET`/`POST` requests are
/// supported.  All DNS resolution is delegated to the SOCKS5 server (SOCKS5H
/// semantics), so the local machine never performs DNS lookups for proxied
/// traffic — preventing DNS leaks.
///
/// Usage:
/// ```dart
/// final port = await HttpBridgeService.instance.start(
///   socks5Host: '127.0.0.1',
///   socks5Port: 1080,
/// );
/// // Configure system / in-app HTTP proxy to 127.0.0.1:port
/// await HttpBridgeService.instance.stop();
/// ```
class HttpBridgeService {
  static final HttpBridgeService instance = HttpBridgeService._();
  HttpBridgeService._();

  ServerSocket? _server;
  int? _port;

  // SOCKS5 upstream config (set on each start() call).
  String _socks5Host = '127.0.0.1';
  int _socks5Port = 1080;
  String _username = '';
  String _password = '';

  /// The local port the bridge is listening on, or `null` when not running.
  int? get port => _port;

  /// Whether the bridge is currently accepting connections.
  bool get isRunning => _server != null;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Binds to `127.0.0.1` on an OS-assigned port, starts accepting
  /// connections, and returns the chosen port number.
  ///
  /// If the bridge is already running it is stopped first.
  Future<int> start({
    required String socks5Host,
    required int socks5Port,
    String username = '',
    String password = '',
  }) async {
    if (_server != null) await stop();

    _socks5Host = socks5Host;
    _socks5Port = socks5Port;
    _username = username;
    _password = password;

    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;

    _server!.listen(
      _handle,
      onError: (_) {},
      cancelOnError: false,
    );

    return _port!;
  }

  /// Closes the listening socket and resets state.  In-flight connections are
  /// left to drain naturally.
  Future<void> stop() async {
    await _server?.close();
    _server = null;
    _port = null;
  }

  // ── SOCKS5 handshake ──────────────────────────────────────────────────────

  /// Opens a TCP connection to the SOCKS5 proxy and negotiates a tunnel to
  /// [targetHost]:[targetPort].
  ///
  /// Always uses `ATYP=0x03` (domain name) so the proxy performs the DNS
  /// lookup — never the local machine.
  ///
  /// Returns a record of:
  /// - [Socket]  — the ready-to-use upstream socket,
  /// - [StreamSubscription] — the subscription owning the socket's byte
  ///   stream, left **paused** so the caller can rewire `onData` safely,
  /// - [List<int>] — any bytes that arrived after the handshake response and
  ///   should be forwarded to the client.
  Future<(Socket, StreamSubscription<List<int>>, List<int>)> _socks5Connect(
    String targetHost,
    int targetPort,
  ) async {
    final socket = await Socket.connect(_socks5Host, _socks5Port);
    socket.setOption(SocketOption.tcpNoDelay, true);

    final buf = _StreamBuffer();
    final sub = socket.listen(
      buf.add,
      onDone: buf.close,
      onError: (_) => buf.close(),
      cancelOnError: false,
    );

    // ── Step 1: Client greeting ───────────────────────────────────────────
    // Advertise "no-auth" (0x00) and, if credentials are configured,
    // also "username/password" (0x02).
    final hasCreds = _username.isNotEmpty;
    socket.add(hasCreds ? [0x05, 0x02, 0x00, 0x02] : [0x05, 0x01, 0x00]);

    // ── Step 2: Server method selection ──────────────────────────────────
    final methodResp = await buf.readExact(2);
    if (methodResp[0] != 0x05) {
      throw Exception(
        'SOCKS5: unexpected server version byte ${methodResp[0]}',
      );
    }
    final method = methodResp[1];

    if (method == 0xFF) {
      throw Exception('SOCKS5: server rejected all offered auth methods');
    }

    if (method == 0x02) {
      // ── Username/password sub-negotiation (RFC 1929) ───────────────────
      final encodedUser = utf8.encode(_username);
      final encodedPass = utf8.encode(_password);
      socket.add([
        0x01, // VER
        encodedUser.length,
        ...encodedUser,
        encodedPass.length,
        ...encodedPass,
      ]);
      final authResp = await buf.readExact(2);
      if (authResp[1] != 0x00) {
        throw Exception(
          'SOCKS5: authentication failed (status=0x'
          '${authResp[1].toRadixString(16).padLeft(2, "0")})',
        );
      }
    }

    // ── Step 3: CONNECT request (domain-name ATYP) ────────────────────────
    final hostnameBytes = utf8.encode(targetHost);
    socket.add([
      0x05, 0x01, 0x00, // VER CMD RSV
      0x03, // ATYP: domain name
      hostnameBytes.length,
      ...hostnameBytes,
      (targetPort >> 8) & 0xFF,
      targetPort & 0xFF,
    ]);

    // ── Step 4: Server response header (4 bytes) ──────────────────────────
    final respHeader = await buf.readExact(4);
    if (respHeader[0] != 0x05) {
      throw Exception(
        'SOCKS5: unexpected response version byte ${respHeader[0]}',
      );
    }
    if (respHeader[1] != 0x00) {
      throw Exception(
        'SOCKS5: CONNECT failed '
        '(REP=0x${respHeader[1].toRadixString(16).padLeft(2, "0")})',
      );
    }

    // ── Step 5: Skip the BND address field ───────────────────────────────
    final atyp = respHeader[3];
    switch (atyp) {
      case 0x01: // IPv4: 4-byte addr + 2-byte port
        await buf.readExact(6);
      case 0x03: // Domain: 1-byte len + len bytes + 2-byte port
        final lenByte = await buf.readExact(1);
        await buf.readExact(lenByte[0] + 2);
      case 0x04: // IPv6: 16-byte addr + 2-byte port
        await buf.readExact(18);
      default:
        throw Exception(
          'SOCKS5: unknown BND ATYP '
          '0x${atyp.toRadixString(16).padLeft(2, "0")}',
        );
    }

    // ── Step 6: Pause, capture leftover bytes, return ─────────────────────
    sub.pause();
    final leftover = buf.drain();
    return (socket, sub, leftover);
  }

  // ── HTTP CONNECT tunnel ───────────────────────────────────────────────────

  /// Handles an HTTP `CONNECT` request by establishing a SOCKS5 tunnel and
  /// wiring bidirectional pipes between [client] and the upstream socket.
  ///
  /// [clientSub] must be **paused** by the caller before this method is
  /// invoked.
  Future<void> _handleConnect(
    String target,
    Socket client,
    StreamSubscription<List<int>> clientSub,
    _StreamBuffer clientBuf,
  ) async {
    // Parse host:port from the CONNECT target (handle IPv6 addresses too).
    final colonIdx = target.lastIndexOf(':');
    final host = target.substring(0, colonIdx);
    final port = int.parse(target.substring(colonIdx + 1));

    final (upstream, upstreamSub, leftover) = await _socks5Connect(host, port);

    // Inform the client the tunnel is open.
    try {
      client.add(
        latin1.encode('HTTP/1.1 200 Connection established\r\n\r\n'),
      );
    } catch (_) {
      upstreamSub.cancel();
      try {
        upstream.destroy();
      } catch (_) {}
      return;
    }

    // ── client → upstream ─────────────────────────────────────────────────
    // 1. Rewire onData while the sub is paused (no delivery races).
    // 2. Flush any bytes that arrived between the header read and the pause.
    // 3. Resume — subsequent bytes flow directly.
    clientSub
      ..onData((data) {
        try {
          upstream.add(data);
        } catch (_) {}
      })
      ..onDone(() {
        try {
          upstream.destroy();
        } catch (_) {}
      })
      ..onError((_) {
        try {
          upstream.destroy();
        } catch (_) {}
      });
    final clientDrained = clientBuf.drain();
    if (clientDrained.isNotEmpty) {
      try {
        upstream.add(clientDrained);
      } catch (_) {}
    }
    clientSub.resume();

    // ── upstream → client ─────────────────────────────────────────────────
    // upstreamSub is already paused (returned that way by _socks5Connect).
    upstreamSub
      ..onData((data) {
        try {
          client.add(data);
        } catch (_) {}
      })
      ..onDone(() {
        try {
          client.destroy();
        } catch (_) {}
      })
      ..onError((_) {
        try {
          client.destroy();
        } catch (_) {}
      });
    if (leftover.isNotEmpty) {
      try {
        client.add(leftover);
      } catch (_) {}
    }
    upstreamSub.resume();
  }

  // ── Plain HTTP proxy (GET / POST / etc.) ──────────────────────────────────

  /// Handles a plain HTTP proxy request by forwarding a rewritten request
  /// through a SOCKS5 tunnel and piping the response back.
  ///
  /// The request line is rewritten to path-relative form and `Proxy-*` headers
  /// are stripped so the origin server does not see proxy metadata.
  ///
  /// [clientSub] must be **paused** by the caller before this method is
  /// invoked.
  Future<void> _handlePlainHttp(
    String method,
    String rawUrl,
    List<String> headerLines,
    Socket client,
    StreamSubscription<List<int>> clientSub,
    _StreamBuffer clientBuf,
  ) async {
    final uri = Uri.parse(rawUrl);
    final host = uri.host;
    // Use the explicit port if present; otherwise fall back to scheme default.
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);

    final (upstream, upstreamSub, leftover) = await _socks5Connect(host, port);

    // Rewrite request line: strip scheme + authority, keep path + query.
    final pathAndQuery = uri.hasQuery
        ? '${uri.path}?${uri.query}'
        : (uri.path.isEmpty ? '/' : uri.path);

    // Drop Proxy-* headers (Proxy-Connection, Proxy-Authorization, etc.).
    final filteredHeaders = headerLines
        .where((line) => !line.toLowerCase().startsWith('proxy-'))
        .toList();

    // latin1 is byte-safe for HTTP/1.x headers.
    final rewritten = latin1.encode(
      '$method $pathAndQuery HTTP/1.1\r\n'
      '${filteredHeaders.join("\r\n")}\r\n'
      '\r\n',
    );

    // Any body bytes that arrived while we were reading headers.
    final bodyBytes = clientBuf.drain();

    try {
      upstream.add(rewritten);
      if (bodyBytes.isNotEmpty) upstream.add(bodyBytes);
    } catch (_) {
      upstreamSub.cancel();
      try {
        upstream.destroy();
      } catch (_) {}
      try {
        client.destroy();
      } catch (_) {}
      return;
    }

    // ── client → upstream ─────────────────────────────────────────────────
    clientSub
      ..onData((data) {
        try {
          upstream.add(data);
        } catch (_) {}
      })
      ..onDone(() {
        try {
          upstream.destroy();
        } catch (_) {}
      })
      ..onError((_) {
        try {
          upstream.destroy();
        } catch (_) {}
      });
    clientSub.resume();

    // ── upstream → client ─────────────────────────────────────────────────
    upstreamSub
      ..onData((data) {
        try {
          client.add(data);
        } catch (_) {}
      })
      ..onDone(() {
        try {
          client.destroy();
        } catch (_) {}
      })
      ..onError((_) {
        try {
          client.destroy();
        } catch (_) {}
      });
    if (leftover.isNotEmpty) {
      try {
        client.add(leftover);
      } catch (_) {}
    }
    upstreamSub.resume();
  }

  // ── Connection dispatcher ─────────────────────────────────────────────────

  /// Entry point for every new client connection accepted by [_server].
  ///
  /// Reads the HTTP header block, classifies the request, then delegates to
  /// [_handleConnect] or [_handlePlainHttp].  Any unhandled error results in
  /// the client socket being closed immediately.
  Future<void> _handle(Socket client) async {
    client.setOption(SocketOption.tcpNoDelay, true);

    final clientBuf = _StreamBuffer();

    // The subscription is created active (not paused) so that incoming bytes
    // are buffered immediately.  It is paused below, before the async SOCKS5
    // handshake, to avoid delivery races when onData is rewired.
    late final StreamSubscription<List<int>> clientSub;
    clientSub = client.listen(
      clientBuf.add,
      onDone: clientBuf.close,
      onError: (_) => clientBuf.close(),
      cancelOnError: false,
    );

    try {
      // Collect the full HTTP header block (everything up to \r\n\r\n).
      final headerBytes = await clientBuf.readUntil(_kDoubleCrlf);
      if (headerBytes == null) {
        // Stream closed before a complete header was received.
        clientSub.cancel();
        client.destroy();
        return;
      }

      // Pause before the async SOCKS5 handshake so no new bytes are delivered
      // to the old onData handler while we rewire the pipe.
      clientSub.pause();

      // latin1 preserves every byte value — safe for raw HTTP/1.x headers.
      final headerText = latin1.decode(headerBytes);
      final lines = headerText.split('\r\n');
      final requestLine = lines[0];

      // Collect non-empty header lines (skip the blank terminal line).
      final headerLines = lines.skip(1).where((l) => l.isNotEmpty).toList();

      final parts = requestLine.split(' ');
      if (parts.length < 2) {
        clientSub.cancel();
        client.destroy();
        return;
      }

      final requestMethod = parts[0];
      final requestTarget = parts[1];

      if (requestMethod == 'CONNECT') {
        await _handleConnect(requestTarget, client, clientSub, clientBuf);
      } else {
        await _handlePlainHttp(
          requestMethod,
          requestTarget,
          headerLines,
          client,
          clientSub,
          clientBuf,
        );
      }
    } catch (_) {
      clientSub.cancel();
      try {
        client.destroy();
      } catch (_) {}
    }
  }
}
