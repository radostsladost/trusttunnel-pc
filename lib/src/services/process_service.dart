import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import 'elevated_task_service.dart';
import 'http_bridge_service.dart';
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
/// - **TUN elevation (macOS)**: Uses `osascript do shell script … with
///   administrator privileges` to show the native password dialog.  The binary
///   is started in the background via a wrapper script; its output is
///   redirected to a temp log file and streamed back into [logStream] via
///   `tail -F`.  The osascript process blocks until the binary exits, giving
///   us a real sentinel Process for lifecycle tracking.
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
  int?
      _childPid; // PID of trusttunnel_client (not the pkexec/osascript wrapper)
  String? _wrapperScriptPath;
  String? _pidFilePath;
  String? _configPath;

  // macOS elevated-mode helpers
  Process? _macOsTailProcess; // `tail -F` streaming the elevated binary's log
  String? _macOsLogFilePath; // temp log file written by the elevated binary

  // macOS TUN networking state (routes + DNS managed by this app)
  String? _macOsTunInterface; // e.g. "utun3"
  String? _macOsOriginalGateway; // default gw before VPN
  String? _macOsVpnServerIp; // resolved VPN server IP
  List<String> _macOsPreExistingUtun = []; // utun ifaces before we started
  final Map<String, List<String>> _macOsSavedDns = {}; // service→ original DNS

  // Windows TUN networking state (routes managed by this app)
  int? _winTunIfIndex; // interface index of the TrustTunnel wintun adapter
  String? _winOriginalGateway; // default gateway before VPN
  String? _winVpnServerIp; // resolved VPN server IP

  ListenerType? _activeListenerType;
  String _activeSocks5Address = '127.0.0.1:1080';
  String _activeSocks5Username = '';
  String _activeSocks5Password = '';

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
    _activeSocks5Username = profile.socks5Username;
    _activeSocks5Password = profile.socks5Password;

    // Launch the process.
    final needsElevation = profile.listenerType == ListenerType.tun &&
        (Platform.isLinux || Platform.isMacOS);

    // Snapshot existing utun interfaces so we can identify the new one later.
    if (needsElevation && Platform.isMacOS) {
      _macOsPreExistingUtun = await _listUtunInterfaces();
    }

    // Windows TUN mode: pre-flight checks before attempting to start.
    if (profile.listenerType == ListenerType.tun && Platform.isWindows) {
      await _checkWindowsTunPrerequisites(binaryPath);
    }

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

    // On macOS TUN mode: detect the new utun interface, apply routes if the
    // binary didn't, and update system DNS so queries go through the tunnel.
    if (profile.listenerType == ListenerType.tun && Platform.isMacOS) {
      await _setupMacOsTunNetworking(profile).catchError((Object e) {
        _log('[APP] TUN network setup warning: $e');
      });
    }

    // On Windows TUN mode: set up routing table to send traffic through the
    // wintun adapter the binary created.
    if (profile.listenerType == ListenerType.tun && Platform.isWindows) {
      await _setupWindowsTunNetworking(profile).catchError((Object e) {
        _log('[APP] Windows TUN network setup warning: $e');
      });
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

    // Stop the macOS log tail immediately.
    _macOsTailProcess?.kill();
    _macOsTailProcess = null;

    if (process == null) return;

    // Clear system proxy synchronously before returning so the user's
    // browser stops using the proxy as soon as they disconnect.
    if (listenerType == ListenerType.socks5) {
      await _clearSystemProxy().catchError((_) {});
    }

    // On macOS TUN mode: restore DNS and remove routes we may have added.
    if (listenerType == ListenerType.tun && Platform.isMacOS) {
      await _teardownMacOsTunNetworking().catchError((_) {});
    }

    // On Windows TUN mode: remove the routes we added.
    if (listenerType == ListenerType.tun && Platform.isWindows) {
      await _teardownWindowsTunNetworking().catchError((_) {});
    }

    _log('[APP] Stopping VPN process...');

    // Signal the process.
    _sendTermSignal(process);

    // For Linux TUN mode: also try to kill the real child if we know its PID.
    // This handles pkexec versions that do not forward SIGTERM.
    if (childPid != null && Platform.isLinux) {
      _tryElevatedKill(childPid, force: false);
    }

    // For macOS TUN mode: the binary runs as root independently of the
    // osascript sentinel process, so we must kill it separately.
    if (childPid != null && Platform.isMacOS) {
      _tryMacOsElevatedKill(childPid, force: false);
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
      if (childPid != null && Platform.isMacOS) {
        _tryMacOsElevatedKill(childPid, force: true);
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

  // ─────────────────────────────────────────────────────────────────────────
  // Windows TUN pre-flight checks
  // ─────────────────────────────────────────────────────────────────────────

  /// Verifies that the current process has administrator privileges and that
  /// wintun.dll is present next to the binary.  Throws a human-readable
  /// [Exception] if either requirement is not met so the UI can surface it.
  ///
  /// If the app is not elevated but the "elevated launch" scheduled task is
  /// registered, the app automatically relaunches via the task (no UAC prompt)
  /// and exits the current non-elevated instance.
  Future<void> _checkWindowsTunPrerequisites(String binaryPath) async {
    // Check for wintun.dll in the same directory as the binary.
    final binDir = File(binaryPath).parent.path;
    final wintunPath = '$binDir${Platform.pathSeparator}wintun.dll';
    if (!File(wintunPath).existsSync()) {
      throw Exception(
        'wintun.dll not found in the TrustTunnel directory.\n'
        'Please reinstall the client so that wintun.dll is placed next to '
        'trusttunnel_client.exe.\n'
        'Expected location: $wintunPath',
      );
    }

    // Confirm the app is running with administrator privileges.
    // WFP (Windows Filtering Platform) requires admin; without it,
    // FwpmTransactionBegin0 will fail with 0x5 (ERROR_ACCESS_DENIED).
    final isAdmin = await ElevatedTaskService.isElevated();
    if (!isAdmin) {
      // If the one-time elevated task has been registered, relaunch via it
      // — the new instance will be elevated with zero UAC prompts.
      if (await ElevatedTaskService.isRegistered()) {
        _log('[APP] Not elevated — relaunching via scheduled task…');
        await ElevatedTaskService.relaunchElevated();
        // relaunchElevated() calls exit(0), so nothing below executes.
        return;
      }

      throw Exception(
        'TUN mode requires administrator privileges.\n\n'
        'To avoid UAC prompts permanently:\n'
        '  Settings → Windows Elevation → Set up elevated launch.\n\n'
        'Or right-click trustunnel_pc.exe → Run as administrator.',
      );
    }
  }

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

  /// macOS TUN: uses `osascript` to show the native administrator dialog.
  ///
  /// Strategy:
  ///  1. A tiny sh wrapper is written to /tmp.  It starts the binary in the
  ///     background, writes its PID, then `wait`s – so osascript (our sentinel
  ///     Process) stays alive exactly as long as the binary does.
  ///  2. Binary output is redirected to a temp log file, then tailed via
  ///     `tail -F` so [_logController] / [_waitForReady] work normally.
  ///  3. On [stop]: SIGTERM goes to the osascript sentinel AND the real PID is
  ///     killed via a second osascript call (auth stays cached for ~5 min).
  Future<void> _startWithMacOsElevation(String binaryPath) async {
    final tmpBase = '/tmp/tt_${DateTime.now().millisecondsSinceEpoch}';
    _wrapperScriptPath = '${tmpBase}_run.sh';
    _pidFilePath = '${tmpBase}_pid.txt';
    _macOsLogFilePath = '$tmpBase.log';

    // Escape a value for embedding inside a shell double-quoted string.
    // (macOS paths never contain backslashes, but may contain double-quotes
    //  or spaces – quoting the entire path handles spaces already.)
    String esc(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

    // Wrapper: start binary in background, save PID, then wait so that the
    // osascript process (our sentinel) blocks until the binary exits.
    final wrapperContent = '#!/bin/sh\n'
        '"${esc(binaryPath)}" -c "${esc(_configPath!)}"'
        ' >> "${esc(_macOsLogFilePath!)}" 2>&1 &\n'
        'CHILD=\$!\n'
        'echo "\$CHILD" > "${esc(_pidFilePath!)}"\n'
        'wait "\$CHILD"\n';
    await File(_wrapperScriptPath!).writeAsString(wrapperContent);
    await Process.run('chmod', ['+x', _wrapperScriptPath!]);

    // Touch the log file before starting so `tail -F` can open it immediately.
    await File(_macOsLogFilePath!).writeAsString('');

    // Build the AppleScript.  The wrapper path is double-quoted inside the
    // shell command, which is itself double-quoted inside the AppleScript
    // string → we escape `"` as `\"` for the AppleScript layer.
    final escapedWrapper = _wrapperScriptPath!.replaceAll('"', r'\"');
    final appleScript =
        'do shell script "\\"$escapedWrapper\\"" with administrator privileges';

    // Process.start returns immediately; the actual dialog is shown by
    // osascript.  _process stays non-null while the binary is alive.
    _process = await Process.start(
      'osascript',
      ['-e', appleScript],
      runInShell: false,
    );
    // osascript's own stdout/stderr carry minimal info; real output is tailed.
    _pipeOutput(_process!);
    _watchExit(_process!);

    // Give the wrapper script ~400 ms to write the PID file before we read it.
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      final pidStr = await File(_pidFilePath!).readAsString();
      _childPid = int.tryParse(pidStr.trim());
      if (_childPid != null) {
        _log('[APP] Elevated TUN process started (PID: $_childPid)');
      }
    } catch (_) {
      _log('[APP] Elevated TUN process started (PID unknown)');
    }

    // Stream the binary's log output into _logController so _waitForReady
    // and the UI log view work as normal.
    await _startMacOsLogTail(_macOsLogFilePath!);
  }

  /// Starts `tail -F` on [logFile] and pipes every line into [_logController].
  Future<void> _startMacOsLogTail(String logFile) async {
    try {
      final tailProc = await Process.start('tail', ['-F', '-n', '+1', logFile]);
      _macOsTailProcess = tailProc;
      tailProc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_log, onError: (_) {}, cancelOnError: false);
      tailProc.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
            (l) => _log('[ERR] $l'),
            onError: (_) {},
            cancelOnError: false,
          );
    } catch (e) {
      _log('[APP] Could not start log tail: $e');
    }
  }

  /// Kills [pid] (running as root on macOS) via a second `osascript` call.
  /// macOS caches the user's auth for ~5 minutes, so this rarely re-prompts.
  void _tryMacOsElevatedKill(int pid, {required bool force}) {
    final sig = force ? '-9' : '-15';
    final appleScript = 'do shell script "kill $sig $pid 2>/dev/null; true" '
        'with administrator privileges';
    Process.run('osascript', ['-e', appleScript])
        .catchError((_) => ProcessResult(0, 1, '', ''));
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
    process.exitCode.then((code) async {
      _log('[PROCESS] Exited with code $code');
      if (identical(process, _process)) {
        _process = null;
        _childPid = null;
        // If the binary exited on its own, clean up the macOS log tail too.
        _macOsTailProcess?.kill();
        _macOsTailProcess = null;

        // On unexpected exit, tear down any routes / proxy we own so the
        // OS is left in a clean state while the app decides whether to
        // reconnect.
        final listenerType = _activeListenerType;
        if (listenerType == ListenerType.tun) {
          if (Platform.isMacOS) {
            await _teardownMacOsTunNetworking().catchError((_) {});
          } else if (Platform.isWindows) {
            await _teardownWindowsTunNetworking().catchError((_) {});
          }
        } else if (listenerType == ListenerType.socks5) {
          // Stop the HTTP bridge so its port is freed; leave the system proxy
          // registry entry pointing to the (now-dead) ports so traffic fails
          // closed rather than bypassing the proxy while we reconnect.
          await HttpBridgeService.instance.stop().catchError((_) {});
        }
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
    if (_macOsLogFilePath != null) {
      File(_macOsLogFilePath!)
          .delete()
          .catchError((Object _) => File(_macOsLogFilePath!));
      _macOsLogFilePath = null;
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – macOS TUN networking (interface detection, routes, DNS)
  // ─────────────────────────────────────────────────────────────────────────

  /// Returns the names of all utun interfaces currently visible to ifconfig.
  Future<List<String>> _listUtunInterfaces() async {
    try {
      final r = await Process.run(
          'sh', ['-c', "ifconfig | awk -F: '/^utun/{print \$1}'"]);
      return (r.stdout as String)
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.startsWith('utun'))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Polls for up to 4 s for a utun interface that wasn't in
  /// [_macOsPreExistingUtun], returning its name or empty string.
  Future<String> _findNewUtunInterface() async {
    for (var i = 0; i < 8; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      final current = await _listUtunInterfaces();
      for (final iface in current) {
        if (!_macOsPreExistingUtun.contains(iface)) return iface;
      }
    }
    return '';
  }

  /// Runs [shellCmd] via `osascript do shell script … with administrator
  /// privileges`.  macOS caches the auth from the initial binary start so
  /// this rarely shows a password prompt.
  Future<ProcessResult> _runElevated(String shellCmd) {
    final escaped = shellCmd.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return Process.run(
      'osascript',
      ['-e', 'do shell script "$escaped" with administrator privileges'],
    ).catchError((_) => ProcessResult(0, 1, '', ''));
  }

  /// Returns true if the kernel routing table already has a default-like
  /// route pointing at [iface] (meaning the binary set it up itself).
  Future<bool> _hasUtunDefaultRoute(String iface) async {
    try {
      final r = await Process.run('netstat', ['-rn', '-f', 'inet']);
      final lines = (r.stdout as String).split('\n');
      // Look for a 0/1 or default route through this interface.
      return lines.any((l) =>
          l.contains(iface) &&
          (l.startsWith('0/1') ||
              l.startsWith('128/1') ||
              l.startsWith('0.0.0.0')));
    } catch (_) {
      return false;
    }
  }

  /// Full macOS TUN post-connect setup:
  ///   1. Detect the utun interface the binary created.
  ///   2. Add split-default routes (0/1 + 128/1) if the binary didn't.
  ///   3. Set system DNS on every active network service.
  ///   4. Log diagnostic snapshot.
  Future<void> _setupMacOsTunNetworking(TrustTunnelProfile profile) async {
    _log('[APP] Configuring macOS network for TUN mode…');

    // 1. Find the new utun interface.
    _macOsTunInterface = await _findNewUtunInterface();
    if (_macOsTunInterface == null || _macOsTunInterface!.isEmpty) {
      _log('[APP] Warning: no new utun interface detected – '
          'the binary may have failed silently.');
      _macOsTunInterface = null;
    } else {
      _log('[APP] TUN interface detected: $_macOsTunInterface');
    }

    // 2. Resolve original default gateway (needed for the server-IP exception
    //    route and for route teardown).
    try {
      final r = await Process.run('sh', [
        '-c',
        "route -n get default 2>/dev/null | awk '/gateway:/{print \$2}'"
      ]);
      _macOsOriginalGateway = (r.stdout as String).trim();
      if (_macOsOriginalGateway!.isNotEmpty) {
        _log('[APP] Original default gateway: $_macOsOriginalGateway');
      }
    } catch (_) {}

    // 3. Resolve the VPN server IP (to protect it from the tunnel route).
    _macOsVpnServerIp = await _resolveVpnServerIp(profile);
    if (_macOsVpnServerIp != null) {
      _log('[APP] VPN server IP: $_macOsVpnServerIp');
    }

    // 4. Apply routes only if the binary hasn't done it already.
    final iface = _macOsTunInterface;
    if (iface != null) {
      final alreadyRouted = await _hasUtunDefaultRoute(iface);
      if (!alreadyRouted) {
        _log('[APP] Binary did not set default routes – applying manually…');
        await _applyMacOsTunRoutes(iface);
      } else {
        _log('[APP] Default routes already in place via $iface.');
      }
    }

    // 5. Update system DNS so queries go through the VPN DNS upstreams.
    if (profile.dnsUpstreams.isNotEmpty) {
      await _applyMacOsDns(profile.dnsUpstreams);
    } else {
      _log('[APP] No DNS upstreams in profile – system DNS unchanged.');
    }

    // 6. Log a quick diagnostic snapshot.
    _logMacOsNetDiag();
  }

  /// Applies split-default routes through [iface], plus a host route for the
  /// VPN server itself so it still reaches the real gateway.
  Future<void> _applyMacOsTunRoutes(String iface) async {
    final cmds = <String>[];

    // Server exception route: VPN server traffic must NOT go through the
    // tunnel, otherwise we create a routing loop.
    final serverIp = _macOsVpnServerIp;
    final gw = _macOsOriginalGateway;
    if (serverIp != null && gw != null && gw.isNotEmpty) {
      cmds.add('route add -host $serverIp $gw 2>/dev/null || true');
    }

    // Split-default: 0/1 + 128/1 together cover the entire IPv4 space and
    // take precedence over the existing 0/0 default via the physical interface.
    cmds.add(
        'route add -net 0.0.0.0/1   -interface $iface 2>/dev/null || true');
    cmds.add(
        'route add -net 128.0.0.0/1 -interface $iface 2>/dev/null || true');

    final result = await _runElevated(cmds.join(' && '));
    if (result.exitCode == 0) {
      _log('[APP] Routes applied: 0/1 + 128/1 → $iface');
    } else {
      _log('[APP] Route setup warning (exit ${result.exitCode}): '
          '${result.stderr}');
    }
  }

  /// Resolves the VPN server to an IPv4 address.  Prefers an address already
  /// in the profile, falls back to DNS lookup of the hostname.
  Future<String?> _resolveVpnServerIp(TrustTunnelProfile profile) async {
    for (final addr in profile.addresses) {
      if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\$').hasMatch(addr)) {
        return addr;
      }
    }
    try {
      final addrs = await InternetAddress.lookup(
        profile.hostname,
        type: InternetAddressType.IPv4,
      );
      if (addrs.isNotEmpty) return addrs.first.address;
    } catch (_) {}
    return null;
  }

  /// Sets the DNS servers for every active macOS network service to [servers],
  /// first saving the originals so they can be restored on disconnect.
  Future<void> _applyMacOsDns(List<String> servers) async {
    _macOsSavedDns.clear();

    final listR =
        await Process.run('networksetup', ['-listallnetworkservices']);
    final services = (listR.stdout as String)
        .split('\n')
        .map((s) => s.trim())
        .where((s) =>
            s.isNotEmpty &&
            !s.contains('*') &&
            !s.toLowerCase().contains('asterisk'))
        .toList();

    final dnsArgs = servers.join(' ');
    for (final service in services) {
      // Save current DNS.
      final dnsR =
          await Process.run('networksetup', ['-getdnsservers', service]);
      final out = (dnsR.stdout as String).trim();
      _macOsSavedDns[service] = out.toLowerCase().contains("there aren't")
          ? []
          : out
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty)
              .toList();

      // Set new DNS (needs root).
      final svcEsc = service.replaceAll('"', r'\"');
      await _runElevated('networksetup -setdnsservers "$svcEsc" $dnsArgs');
    }
    _log('[APP] DNS set to: ${servers.join(', ')} '
        'for ${services.length} network service(s).');
  }

  /// Restores each network service's DNS to what it was before the VPN
  /// connected, then clears the saved state.
  Future<void> _restoreMacOsDns() async {
    if (_macOsSavedDns.isEmpty) return;
    for (final entry in _macOsSavedDns.entries) {
      final svcEsc = entry.key.replaceAll('"', r'\"');
      final arg = entry.value.isEmpty ? 'empty' : entry.value.join(' ');
      await _runElevated('networksetup -setdnsservers "$svcEsc" $arg');
    }
    _macOsSavedDns.clear();
    _log('[APP] DNS restored to pre-VPN settings.');
  }

  /// Removes the routes and DNS changes made by [_setupMacOsTunNetworking].
  Future<void> _teardownMacOsTunNetworking() async {
    final iface = _macOsTunInterface;
    final serverIp = _macOsVpnServerIp;

    if (iface != null && iface.isNotEmpty) {
      final cmds = [
        'route delete -net 0.0.0.0/1   -interface $iface 2>/dev/null || true',
        'route delete -net 128.0.0.0/1 -interface $iface 2>/dev/null || true',
        if (serverIp != null)
          'route delete -host $serverIp 2>/dev/null || true',
      ];
      await _runElevated(cmds.join(' && '));
      _log('[APP] TUN routes removed.');
    }

    await _restoreMacOsDns();

    _macOsTunInterface = null;
    _macOsOriginalGateway = null;
    _macOsVpnServerIp = null;
    _macOsPreExistingUtun = [];
  }

  /// Logs a quick network snapshot to the log stream (non-blocking).
  void _logMacOsNetDiag() {
    Future(() async {
      try {
        // Active utun interfaces
        final utunR = await Process.run('sh',
            ['-c', "ifconfig | awk '/^utun/{p=1} p{print; if(/^\$/)p=0}'"]);
        _log('[DIAG] TUN interfaces:\n${(utunR.stdout as String).trim()}');
        // IPv4 routing table
        final routeR = await Process.run('netstat', ['-rn', '-f', 'inet']);
        _log('[DIAG] IPv4 routing table:\n${(routeR.stdout as String).trim()}');
      } catch (_) {}
    });
  }

  // ─────────────────────────────────────────────────────────────────────────
  // Private – Windows TUN networking
  // ─────────────────────────────────────────────────────────────────────────

  /// After the binary connects, find the wintun adapter, save the current
  /// default gateway, add a server-exception route and split-default routes
  /// through the TUN interface so all traffic flows through the VPN.
  Future<void> _setupWindowsTunNetworking(TrustTunnelProfile profile) async {
    _log('[APP] Configuring Windows network for TUN mode…');

    // 1. Poll for the TrustTunnel wintun adapter (up to 4 s).
    _winTunIfIndex = await _findWindowsTunIfIndex();
    if (_winTunIfIndex == null) {
      _log(
          '[APP] Warning: TrustTunnel adapter not found – routes not applied.');
      return;
    }
    _log('[APP] TrustTunnel adapter ifIndex: $_winTunIfIndex');

    // 2. Save the current default gateway.
    _winOriginalGateway = await _getWindowsDefaultGateway();
    if (_winOriginalGateway != null && _winOriginalGateway!.isNotEmpty) {
      _log('[APP] Original default gateway: $_winOriginalGateway');
    }

    // 3. Resolve VPN server IP (so we can keep reaching it via the original gw).
    _winVpnServerIp = await _resolveVpnServerIp(profile);
    if (_winVpnServerIp != null) {
      _log('[APP] VPN server IP: $_winVpnServerIp');
    }

    // 4. Check if the binary already installed a default route on this adapter.
    final alreadyRouted = await _windowsTunHasDefaultRoute(_winTunIfIndex!);
    if (alreadyRouted) {
      _log('[APP] Default route already present on TUN adapter – skipping.');
      return;
    }

    // 5. Get the TUN adapter’s assigned IP (needed as the next-hop).
    final tunIp = await _getWindowsTunAdapterIp(_winTunIfIndex!);
    if (tunIp == null) {
      _log(
          '[APP] Warning: could not determine TUN adapter IP – routes not applied.');
      return;
    }
    _log('[APP] TUN adapter IP: $tunIp');

    // 6. Apply routes.
    await _applyWindowsTunRoutes(tunIp);
  }

  /// Polls `netsh interface ipv4 show interfaces` for up to 4 s until an
  /// interface named "*TrustTunnel*" appears.  Returns its ifIndex, or null.
  Future<int?> _findWindowsTunIfIndex() async {
    for (var attempt = 0; attempt < 8; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final r = await Process.run(
          'powershell',
          [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            r"(Get-NetAdapter | Where-Object {$_.Name -like '*TrustTunnel*'} | Select-Object -First 1).ifIndex",
          ],
        );
        final out = (r.stdout as String).trim();
        final idx = int.tryParse(out);
        if (idx != null) return idx;
      } catch (_) {}
    }
    return null;
  }

  /// Returns the IPv4 address assigned to the given adapter interface index.
  Future<String?> _getWindowsTunAdapterIp(int ifIndex) async {
    try {
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-NetIPAddress -InterfaceIndex $ifIndex -AddressFamily IPv4 '
              '-ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress',
        ],
      );
      final ip = (r.stdout as String).trim();
      return ip.isNotEmpty ? ip : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns the current IPv4 default gateway (before the VPN overrides it).
  Future<String?> _getWindowsDefaultGateway() async {
    try {
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r"(Get-NetRoute -DestinationPrefix '0.0.0.0/0' | "
              r"Sort-Object {$_.InterfaceMetric + $_.RouteMetric} | "
              r"Select-Object -First 1).NextHop",
        ],
      );
      final gw = (r.stdout as String).trim();
      return (gw.isNotEmpty && gw != '0.0.0.0') ? gw : null;
    } catch (_) {
      return null;
    }
  }

  /// Returns true if a 0.0.0.0/0 or 0.0.0.0/1+128.0.0.0/1 default route
  /// already points at [ifIndex] (meaning the binary set it up itself).
  Future<bool> _windowsTunHasDefaultRoute(int ifIndex) async {
    try {
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-NetRoute -InterfaceIndex $ifIndex '
              "-ErrorAction SilentlyContinue | Where-Object {"
              r"$_.DestinationPrefix -eq '0.0.0.0/0' -or "
              r"$_.DestinationPrefix -eq '0.0.0.0/1' -or "
              r"$_.DestinationPrefix -eq '128.0.0.0/1'}).Count",
        ],
      );
      final count = int.tryParse((r.stdout as String).trim()) ?? 0;
      return count > 0;
    } catch (_) {
      return false;
    }
  }

  /// Adds:
  ///   • A host route for the VPN server via the original gateway (loop
  ///     prevention).
  ///   • Two split-default routes (0.0.0.0/1 + 128.0.0.0/1) through [tunIp]
  ///     with a low metric so they take precedence over the physical default.
  Future<void> _applyWindowsTunRoutes(String tunIp) async {
    final serverIp = _winVpnServerIp;
    final origGw = _winOriginalGateway;

    // Exception route: VPN server traffic must bypass the tunnel.
    if (serverIp != null && origGw != null && origGw.isNotEmpty) {
      final r = await Process.run('route', [
        'add',
        serverIp,
        'mask',
        '255.255.255.255',
        origGw,
        'METRIC',
        '1',
      ]);
      if ((r.exitCode) == 0) {
        _log('[APP] Server exception route added: $serverIp → $origGw');
      } else {
        _log('[APP] Server exception route warning: ${r.stderr}');
      }
    }

    // Split-default routes through the TUN adapter.
    for (final prefix in ['0.0.0.0', '128.0.0.0']) {
      final r = await Process.run('route', [
        'add',
        prefix,
        'mask',
        '128.0.0.0',
        tunIp,
        'METRIC',
        '5',
      ]);
      if (r.exitCode == 0) {
        _log('[APP] Route added: $prefix/1 → $tunIp');
      } else {
        _log('[APP] Route add warning ($prefix/1): ${r.stderr}');
      }
    }
  }

  /// Removes the routes added by [_setupWindowsTunNetworking].
  Future<void> _teardownWindowsTunNetworking() async {
    final serverIp = _winVpnServerIp;
    final origGw = _winOriginalGateway;

    // Remove server exception route.
    if (serverIp != null && origGw != null) {
      await Process.run('route', [
        'delete',
        serverIp,
        'mask',
        '255.255.255.255',
        origGw,
      ]).catchError((_) => ProcessResult(0, 1, '', ''));
    }

    // Remove split-default routes.
    for (final prefix in ['0.0.0.0', '128.0.0.0']) {
      await Process.run('route', [
        'delete',
        prefix,
        'mask',
        '128.0.0.0',
      ]).catchError((_) => ProcessResult(0, 1, '', ''));
    }

    _log('[APP] Windows TUN routes removed.');
    _winTunIfIndex = null;
    _winOriginalGateway = null;
    _winVpnServerIp = null;
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
      // Start the HTTP CONNECT bridge so apps that only support HTTP proxy
      // (not SOCKS5) are also routed through the VPN tunnel.
      // The bridge always passes hostnames to the SOCKS5 server, giving
      // SOCKS5H semantics and preventing DNS leaks.
      final socks5Port = int.tryParse(port) ?? 1080;
      final bridgePort = await HttpBridgeService.instance.start(
        socks5Host: host,
        socks5Port: socks5Port,
        username: _activeSocks5Username,
        password: _activeSocks5Password,
      );
      _log('[APP] HTTP bridge started on port $bridgePort');

      // ProxyServer format: protocol=host:port;...  — use all three so that
      // WinINet/WinHTTP apps use SOCKS5 natively while other apps (e.g. some
      // .NET, Java, corporate tools) can fall back to HTTP CONNECT.
      final proxyString = 'socks=$host:$port;'
          'http=127.0.0.1:$bridgePort;'
          'https=127.0.0.1:$bridgePort';

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
        proxyString,
        '/f'
      ]);
      // Notify WinINet and broadcast WM_SETTINGCHANGE so all apps
      // (including Chromium/Edge) immediately pick up the new proxy.
      await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        _winProxyNotifyScript,
      ]);
    }
  }

  // Single PowerShell script used by both _setSystemProxy and
  // _clearSystemProxy to broadcast the proxy-changed notification.
  static const String _winProxyNotifyScript = r'''
try {
  $s1 = '[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h, int o, IntPtr b, int l);'
  Add-Type -MemberDefinition $s1 -Name WI -Namespace TT -ErrorAction SilentlyContinue
  [TT.WI]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
  [TT.WI]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
} catch {}
try {
  $s2 = '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr result);'
  Add-Type -MemberDefinition $s2 -Name U32 -Namespace TT -ErrorAction SilentlyContinue
  $r = [UIntPtr]::Zero
  [TT.U32]::SendMessageTimeout([IntPtr]0xFFFF, 0x1A, [UIntPtr]::Zero, "ProxySetting", 2, 5000, [ref]$r) | Out-Null
} catch {}
''';

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
      // Stop the HTTP bridge before clearing the registry so no new
      // connections arrive after the proxy is disabled.
      await HttpBridgeService.instance.stop().catchError((_) {});

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
      await _run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        _winProxyNotifyScript,
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
