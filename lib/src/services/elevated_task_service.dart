import 'dart:io';

/// Windows-only: manages a Task Scheduler task that runs TrustTunnel with
/// `HighestAvailable` privileges, eliminating per-launch UAC prompts.
///
/// ## Elevation mechanism
///
/// The previous PowerShell approach (`Start-Process -Verb RunAs` inside a
/// `-NonInteractive` shell) silently fails on many systems because
/// `-NonInteractive` can block Windows from showing the UAC consent dialog.
///
/// This implementation uses **`wscript.exe` + `Shell.Application.ShellExecute`
/// with the `"runas"` verb** — the same mechanism used by Windows installers
/// and tools like Chocolatey.  It works because:
///
///   1. `wscript.exe` is always available and is not subject to PowerShell
///      execution-policy restrictions.
///   2. `Shell.Application.ShellExecute` invokes the shell's own elevation
///      path, which always produces the UAC prompt regardless of the calling
///      process's interactivity mode.
///   3. `ShellExecute` is fire-and-forget (returns before schtasks finishes),
///      so we poll `schtasks /query` until the task appears.
///
/// ## Lifecycle
///
/// 1. [register] — writes a task XML + a tiny VBScript, runs the VBScript
///    with `wscript /nologo`.  UAC appears **once**.  Polls for up to 30 s.
/// 2. [relaunchElevated] — calls `schtasks /run`, waits ~800 ms for the
///    elevated instance to open, then calls `exit(0)`.  No UAC.
/// 3. [unregister] — same VBScript pattern; polls until the task is gone.
class ElevatedTaskService {
  ElevatedTaskService._();

  static const String _taskName = 'TrustTunnel_Elevated';

  // ── Queries ──────────────────────────────────────────────────────────────────

  /// Returns `true` if the elevated scheduled task exists for this user.
  static Future<bool> isRegistered() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run(
      'schtasks',
      ['/query', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));
    return r.exitCode == 0;
  }

  /// Returns `true` if the current process is already elevated (admin token).
  ///
  /// Uses `whoami /groups` and checks for the High Mandatory Level SID
  /// (`S-1-16-12288`), which only appears in an elevated token.
  /// Much faster than spawning PowerShell.
  static Future<bool> isElevated() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run(
        'whoami',
        ['/groups'],
        runInShell: false,
      );
      // S-1-16-12288 = High Integrity Level = elevated administrator.
      return r.stdout.toString().contains('S-1-16-12288');
    } catch (_) {
      return false;
    }
  }

  // ── Registration ─────────────────────────────────────────────────────────────

  /// Registers the scheduled task.  Triggers a UAC prompt **exactly once**.
  ///
  /// Throws a descriptive [Exception] if the task is not created within 30 s
  /// (user declined UAC or something went wrong).
  static Future<void> register() async {
    if (!Platform.isWindows) return;

    final exePath = Platform.resolvedExecutable;
    final tmp = Directory.systemTemp.path;
    final xmlPath = '$tmp\\tt_task.xml';
    final vbsPath = '$tmp\\tt_elevate.vbs';

    // ── Step 1: write the task definition ────────────────────────────────────
    await File(xmlPath).writeAsString(_buildTaskXml(exePath));

    // ── Step 2: write a VBScript that elevates schtasks via ShellExecute ─────
    //
    // In VBScript string literals, two consecutive double-quotes ("") represent
    // a single literal double-quote character.  That gives schtasks the
    // properly-quoted /xml and /tn values it needs.
    //
    // The paths themselves can contain backslashes; VBScript does NOT treat
    // backslash as an escape character inside strings, so no extra escaping
    // is needed for directory separators.
    final xmlQ = xmlPath.replaceAll('"', '""'); // escape any quotes in path
    final vbs = StringBuffer()
      ..writeln('Set sh = CreateObject("Shell.Application")')
      ..write('sh.ShellExecute "schtasks.exe", ')
      ..write('"/create /xml ""$xmlQ"" /tn ""$_taskName"" /f", ')
      ..writeln('"", "runas", 1');

    await File(vbsPath).writeAsString(vbs.toString());

    // ── Step 3: run wscript ───────────────────────────────────────────────────
    //
    // wscript launches ShellExecute and returns immediately.
    // The UAC dialog appears asynchronously from Windows (consent.exe).
    // We must poll because we have no synchronous completion signal.
    await Process.run('wscript', ['/nologo', vbsPath], runInShell: false)
        .catchError((_) => ProcessResult(0, 0, '', ''));

    // ── Step 4: poll until the task appears (up to 30 s) ─────────────────────
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (await isRegistered()) {
        _deleteFiles([xmlPath, vbsPath]);
        return; // success
      }
    }

    _deleteFiles([xmlPath, vbsPath]);
    throw Exception(
      'The scheduled task was not created after 30 seconds.\n\n'
      'Possible causes:\n'
      '  • You clicked "No" (or dismissed) the UAC prompt.\n'
      '  • UAC is disabled by Group Policy on this machine.\n'
      '  • Windows Script Host (wscript.exe) is disabled by policy.\n\n'
      'Workaround: right-click trustunnel_pc.exe → Run as administrator, '
      'then try again from Settings.',
    );
  }

  // ── Unregistration ───────────────────────────────────────────────────────────

  /// Removes the scheduled task.  Triggers a UAC prompt once.
  static Future<void> unregister() async {
    if (!Platform.isWindows) return;

    final vbsPath = '${Directory.systemTemp.path}\\tt_unreg.vbs';
    final vbs = StringBuffer()
      ..writeln('Set sh = CreateObject("Shell.Application")')
      ..write('sh.ShellExecute "schtasks.exe", ')
      ..write('"/delete /tn ""$_taskName"" /f", ')
      ..writeln('"", "runas", 1');

    await File(vbsPath).writeAsString(vbs.toString());

    await Process.run('wscript', ['/nologo', vbsPath], runInShell: false)
        .catchError((_) => ProcessResult(0, 0, '', ''));

    // Poll until the task is gone (up to 10 s).
    for (var i = 0; i < 20; i++) {
      await Future.delayed(const Duration(milliseconds: 500));
      if (!await isRegistered()) break;
    }

    _deleteFiles([vbsPath]);
  }

  // ── Relaunch ─────────────────────────────────────────────────────────────────

  /// Fires the scheduled task (elevated, no UAC) and exits the current
  /// non-elevated process.
  ///
  /// Task Scheduler launches a new elevated instance within ~1 s; the user
  /// sees the app reopen without any dialog.
  static Future<void> relaunchElevated() async {
    await Process.run(
      'schtasks',
      ['/run', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));

    // Give Task Scheduler a moment to spin up the elevated window before
    // we close so the user doesn't see a gap.
    await Future.delayed(const Duration(milliseconds: 800));
    exit(0);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  static void _deleteFiles(List<String> paths) {
    for (final p in paths) {
      File(p).delete().catchError((_) => File(p));
    }
  }

  // ── Task XML ─────────────────────────────────────────────────────────────────

  static String _buildTaskXml(String exePath) {
    // Escape characters reserved in XML attribute/element values.
    final esc = exePath
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');

    return '''<?xml version="1.0" encoding="UTF-8"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>TrustTunnel VPN – elevated launch (no UAC prompts)</Description>
  </RegistrationInfo>
  <Triggers/>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$esc</Command>
    </Exec>
  </Actions>
</Task>''';
  }
}
