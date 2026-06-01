import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import 'storage_service.dart';
import 'toml_service.dart';

/// Manages the lifecycle of a running `trusttunnel_client` subprocess.
///
/// Design decisions that address known failure modes:
///
/// - **TUN elevation (Linux)**: Uses a bash wrapper script run via `pkexec`.
///   The wrapper traps SIGTERM/INT and forwards the signal to the real child
///   process, working around pkexec versions that do not auto-forward signals.
///   It also writes the child PID to a temp file so we can attempt a direct
///   elevated kill as a last resort.
///
/// - **Connection detection**: `start()` listens to log output and resolves
///   only when a "ready" indicator is seen (or after a 20-second fallback).
///   This prevents the UI from reporting "Connected" before the tunnel is up.
///
/// - **Non-blocking stop**: `stop()` sends SIGTERM and returns immediately.
///   The process is given up to 8 seconds to exit cleanly, then SIGKILL is
///   sent in the background. The UI is unblocked right away.
///
/// - **SOCKS5 system proxy**: When a SOCKS5 profile is active, the system-wide
///   proxy is set automatically on connect and cleared on disconnect (Linux
///   GNOME, macOS, Windows).
class ProcessService {
  static ProcessService? _instance;
  static ProcessService get instance => _instance ??= ProcessService._();
  ProcessService._();

  Process? _process;
  int? _childPid; // PID of trusttunnel_client (not the pkexec wrapper)
  String? _wrapperScriptPath;
  String? _pidFilePath;
  String? _configPath;

  ListenerType? _activeListenerType;
  String _activeSocks5Address = '127.0.0.1:1080';

  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<String> get logStream => _logController.stream;

  /// True while a client process is tracked (may still be cleaning up after
  /// [stop] is called, but the UI can treat it as stopped immediately).
  bool get isRunning => _process != null;

  String? get configPath => _configPath;

  // ─────────────────────────────────────────────────────────────────────────
  // Start
  // ─────────────────────────────────────────────────────────────────────────

  /// Writes the config, starts the process, and waits until the VPN reports
  /// ready (or up to 20 seconds).  Throws on early process death or timeout.
  Future<void> start({
    required TrustTunnelProfile profile,
    required String binaryPath,
    required String configDir,
  }) async {
    if (_process != null) await stop();

    // Write TOML config.
    _configPath = '$configDir${Platform.pathSeparator}trusttunnel_client.toml';
    final configFile = File(_configPath!);
    await configFile.parent.create(recursive: true);
    // Load global DNS routes file if configured.
    final globalRoutesPath = await StorageService.loadGlobalRoutesFile();
    List<String> extraRoutes = const [];
    if (globalRoutesPath != null && globalRoutesPath.isNotEmpty) {
      try {
        final lines = await File(globalRoutesPath).readAsLines();
        extraRoutes = lines
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .toList();
      } catch (_) {}
    }
    await configFile.writeAsString(
      TomlService.generateToml(profile, extraRoutes: extraRoutes),
    );

    _activeListenerType = profile.listenerType;
    _activeSocks5Address = profile.socks5Address;

    // Launch the process.
    final needsElevation = profile.listenerType == ListenerType.tun &&
        (Platform.isLinux || Platform.isMacOS);

    if (needsElevation && Platform.isLinux) {
      await _startWithLinuxWrapper(binaryPath);
    } else if (needsElevation && Platform.isMacOS) {
      await _startWithMacOsElevation(binaryPath);
    } else {
      await _startDirect(binaryPath);
    }

    // Wait for tunnel to actually come up.
    await _waitForReady();

    // Set system proxy when in SOCKS5 mode.
    if (profile.listenerType == ListenerType.socks5) {
      await _setSystemProxy(_activeSocks5Address).catchError((_) {});
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Stop  (non-blocking – returns once the signal is sent)
  // ─────────────────────────────────────────────────────────────────────────

  /// Sends SIGTERM to the running process and returns immediately.
  ///
  /// Clean-up (proxy clear, force-kill fallback) continues in the background.
  Future<void> stop() async {
    final process = _process;
    final childPid = _childPid;
    final listenerType = _activeListenerType;

    // Null everything out immediately so isRunning becomes false right away
    // and the UI can show "Disconnected" without waiting for process death.
    _process = null;
    _childPid = null;
    _activeListenerType = null;

    if (process == null) return;

    // Clear system proxy synchronously before returning so the user's
    // browser stops using the proxy as soon as they disconnect.
    if (listenerType == ListenerType.socks5) {
      await _clearSystemProxy().catchError((_) {});
    }

    _log('[APP] Stopping VPN process...');

    // Signal the process.
    _sendTermSignal(process);

    // For Linux TUN mode: also try to kill the real child if we know its PID.
    // This handles pkexec versions that do not forward SIGTERM.
    if (childPid != null && Platform.isLinux) {
      _tryElevatedKill(childPid, force: false);
    }

    // Background cleanup: force-kill after 8 seconds.
    process.exitCode.timeout(const Duration(seconds: 8)).then((_) {
      _log('[APP] Process stopped cleanly.');
      _cleanUpWrapperFiles();
    }).catchError((_) {
      _log('[APP] Process did not stop in time – sending SIGKILL.');
      process.kill(); // SIGKILL
      if (childPid != null && Platform.isLinux) {
        _tryElevatedKill(childPid, force: true);
      }
      _cleanUpWrapperFiles();
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Dispose
  // ─────────────────────────────────────────────────────────────────────────

  void dispose() {
    stop();
    _logController.close();
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – process launchers
  // ─────────────────────────────────────────────────────────────────────────

  /// Direct launch (no elevation needed: SOCKS5 mode, or Windows TUN via UAC).
  Future<void> _startDirect(String binaryPath) async {
    _process = await Process.start(
      binaryPath,
      ['-c', _configPath!],
      runInShell: false,
    );
    _pipeOutput(_process!);
    _watchExit(_process!);
  }

  /// Linux TUN: wraps the binary in a bash script run via pkexec so that
  /// SIGTERM is properly forwarded to the child and the child PID is captured.
  Future<void> _startWithLinuxWrapper(String binaryPath) async {
    final tmpBase = '/tmp/tt_${DateTime.now().millisecondsSinceEpoch}';
    _wrapperScriptPath = '${tmpBase}_run.sh';
    _pidFilePath = '${tmpBase}_pid.txt';

    // Write the wrapper script.
    final script = '''#!/bin/bash
# TrustTunnel launcher wrapper – handles signal forwarding
TT_PID_FILE="$_pidFilePath"
cleanup() {
  if [ -n "\$CHILD_PID" ]; then
    kill -TERM "\$CHILD_PID" 2>/dev/null
    wait "\$CHILD_PID" 2>/dev/null
  fi
  rm -f "\$TT_PID_FILE"
  exit 0
}
trap cleanup INT TERM EXIT
"$binaryPath" -c "$_configPath" &
CHILD_PID=\$!
echo "\$CHILD_PID" > "\$TT_PID_FILE"
echo "TT_CHILD_PID:\$CHILD_PID"
wait "\$CHILD_PID"
''';
    await File(_wrapperScriptPath!).writeAsString(script);
    await Process.run('chmod', ['+x', _wrapperScriptPath!]);

    _process = await Process.start(
      'pkexec',
      ['bash', _wrapperScriptPath!],
      runInShell: false,
    );

    // Parse child PID from the first output line, forward rest to log stream.
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.startsWith('TT_CHILD_PID:')) {
        _childPid = int.tryParse(line.substring(13).trim());
        _log('[APP] Tracked child PID: $_childPid');
      } else {
        _log(line);
      }
    }, onError: (_) {}, cancelOnError: false);

    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) => _log('[ERR] $line'),
          onError: (_) {},
          cancelOnError: false,
        );

    _watchExit(_process!);
  }

  /// macOS TUN: uses `osascript` to show the native authentication dialog.
  Future<void> _startWithMacOsElevation(String binaryPath) async {
    final escapedBinary = binaryPath.replaceAll('"', '\\"');
    final escapedConfig = _configPath!.replaceAll('"', '\\"');
    final script =
        'do shell script "\\"$escapedBinary\\" -c \\"$escapedConfig\\"" '
        'with administrator privileges';
    _process = await Process.start(
      'osascript',
      ['-e', script],
      runInShell: false,
    );
    _pipeOutput(_process!);
    _watchExit(_process!);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – connection readiness
  // ─────────────────────────────────────────────────────────────────────────

  static const _readyPatterns = [
    'connected',
    'vpn is up',
    'ready',
    'listening',
    'socks5 proxy',
    'tun interface',
    'started',
    'established',
  ];

  static const _errorPatterns = [
    'permission denied',
    'authentication failed',
    'fatal error',
    'failed to start',
    'error: ',
    'pkexec: ',
  ];

  /// Waits until the process logs a ready indicator, the process is still
  /// alive after 20 s (assumed connected), or dies within 5 s (error).
  Future<void> _waitForReady() async {
    final completer = Completer<void>();

    // Early-death detector: if the process dies within 5 s, it failed.
    Timer? earlyDeathTimer;
    Timer? readyTimer;
    StreamSubscription<String>? logSub;

    void complete([Object? error]) {
      if (completer.isCompleted) return;
      earlyDeathTimer?.cancel();
      readyTimer?.cancel();
      logSub?.cancel();
      if (error != null) {
        completer.completeError(error);
      } else {
        completer.complete();
      }
    }

    earlyDeathTimer = Timer(const Duration(seconds: 5), () {
      if (!isRunning) {
        complete(
          Exception(
            'Process exited immediately.\n'
            'Check that the binary path is correct and you have '
            'the required permissions.',
          ),
        );
      }
    });

    // After 20 s, if still alive → assume connected.
    readyTimer = Timer(const Duration(seconds: 20), () {
      if (isRunning) {
        complete();
      } else {
        complete(Exception('Connection timed out after 20 seconds.'));
      }
    });

    // Watch logs for explicit success / failure patterns.
    logSub = _logController.stream.listen((line) {
      final lower = line.toLowerCase();
      if (_readyPatterns.any(lower.contains)) {
        complete();
        return;
      }
      if (_errorPatterns.any(lower.contains)) {
        complete(Exception('Client reported an error:\n$line'));
      }
    });

    await completer.future;
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – output helpers
  // ─────────────────────────────────────────────────────────────────────────

  void _pipeOutput(Process process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_log, onError: (_) {}, cancelOnError: false);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((l) => _log('[ERR] $l'), onError: (_) {}, cancelOnError: false);
  }

  void _watchExit(Process process) {
    process.exitCode.then((code) {
      _log('[PROCESS] Exited with code $code');
      if (identical(process, _process)) {
        _process = null;
        _childPid = null;
      }
    });
  }

  void _log(String line) {
    if (!_logController.isClosed) _logController.add(line);
  }

  void _sendTermSignal(Process process) {
    try {
      if (Platform.isWindows) {
        process.kill();
      } else {
        process.kill(ProcessSignal.sigterm);
      }
    } catch (_) {
      // Process may have already exited.
    }
  }

  /// Sends SIGTERM (or SIGKILL if [force]) to the real child PID via pkexec,
  /// handling the case where pkexec didn't forward the signal itself.
  void _tryElevatedKill(int pid, {required bool force}) {
    final sig = force ? '-9' : '-TERM';
    Process.run('pkexec', ['kill', sig, pid.toString()])
        .catchError((_) => ProcessResult(0, 1, '', ''));
  }

  void _cleanUpWrapperFiles() {
    if (_wrapperScriptPath != null) {
      File(_wrapperScriptPath!)
          .delete()
          .catchError((Object _) => File(_wrapperScriptPath!));
      _wrapperScriptPath = null;
    }
    if (_pidFilePath != null) {
      File(_pidFilePath!)
          .delete()
          .catchError((Object _) => File(_pidFilePath!));
      _pidFilePath = null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – system proxy management (SOCKS5 mode)
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> _setSystemProxy(String socks5Address) async {
    final parts = socks5Address.split(':');
    final host = parts.isNotEmpty ? parts[0] : '127.0.0.1';
    final port = parts.length > 1 ? parts[1] : '1080';
    _log('[APP] Setting system SOCKS5 proxy: $host:$port');

    if (Platform.isLinux) {
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'manual']);
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.socks', 'host', host]);
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.socks', 'port', port]);
      // Also set http/https to use the SOCKS proxy for apps that don't honour socks
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.http', 'host', host]);
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.http', 'port', port]);
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.https', 'host', host]);
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy.https', 'port', port]);
    } else if (Platform.isMacOS) {
      // Try common network interfaces.
      for (final iface in ['Wi-Fi', 'Ethernet', 'USB 10/100/1000 LAN']) {
        await _run(
            'networksetup', ['-setsocksfirewallproxy', iface, host, port]);
        await _run(
            'networksetup', ['-setsocksfirewallproxystate', iface, 'on']);
      }
    } else if (Platform.isWindows) {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      await _run('reg', [
        'add',
        key,
        '/v',
        'ProxyEnable',
        '/t',
        'REG_DWORD',
        '/d',
        '1',
        '/f'
      ]);
      await _run('reg', [
        'add',
        key,
        '/v',
        'ProxyServer',
        '/t',
        'REG_SZ',
        '/d',
        'socks=$host:$port',
        '/f'
      ]);
      // Notify Windows that proxy settings changed.
      await _run('rundll32.exe', ['wininet.dll,', 'ForceAutodiscovery']);
    }
  }

  Future<void> _clearSystemProxy() async {
    _log('[APP] Clearing system proxy.');
    if (Platform.isLinux) {
      await _run(
          'gsettings', ['set', 'org.gnome.system.proxy', 'mode', 'none']);
    } else if (Platform.isMacOS) {
      for (final iface in ['Wi-Fi', 'Ethernet', 'USB 10/100/1000 LAN']) {
        await _run(
            'networksetup', ['-setsocksfirewallproxystate', iface, 'off']);
      }
    } else if (Platform.isWindows) {
      const key =
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
      await _run('reg', [
        'add',
        key,
        '/v',
        'ProxyEnable',
        '/t',
        'REG_DWORD',
        '/d',
        '0',
        '/f'
      ]);
    }
  }

  /// Runs a command and silently ignores errors (best-effort system calls).
  Future<void> _run(String cmd, List<String> args) async {
    try {
      await Process.run(cmd, args);
    } catch (_) {
      // Silently ignore – system call is best-effort.
    }
  }
}
