import 'dart:io';

/// Windows-only: manages a Task Scheduler task that runs TrustTunnel with
/// `HighestAvailable` privileges, eliminating per-launch UAC prompts.
///
/// ## How it works
///
///  1. [register] writes two temp files:
///       - `tt_register.ps1` — uses `New-ScheduledTaskAction` /
///         `Register-ScheduledTask` (no XML, no encoding issues) and writes
///         `"OK"` or the actual exception message to `tt_status.txt`.
///       - `tt_elevate.vbs` — a two-line VBScript that calls
///         `Shell.Application.ShellExecute` with the `"runas"` verb to start
///         the PS1 file elevated.  This is the most reliable UAC-trigger path
///         on Windows — the same mechanism used by installers and Chocolatey.
///  2. `wscript /nologo tt_elevate.vbs` is executed (returns immediately).
///     The UAC dialog appears asynchronously.
///  3. Dart polls `tt_status.txt` for up to 30 s.  On success the file
///     contains `"OK"`.  On failure it contains the PowerShell exception
///     message, which is shown verbatim so the user knows what went wrong.
///  4. [relaunchElevated] calls `schtasks /run /tn TrustTunnel_Elevated`
///     and calls `exit(0)` — no UAC prompt.
class ElevatedTaskService {
  ElevatedTaskService._();

  static const String _taskName = 'TrustTunnel_Elevated';

  // ── Queries ──────────────────────────────────────────────────────────────────

  /// `true` if the scheduled task already exists for this user.
  static Future<bool> isRegistered() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run(
      'schtasks',
      ['/query', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));
    return r.exitCode == 0;
  }

  /// `true` if this process already has an elevated (admin) token.
  ///
  /// Checks the High Integrity Level SID (`S-1-16-12288`) via `whoami /groups`.
  static Future<bool> isElevated() async {
    if (!Platform.isWindows) return true;
    try {
      final r = await Process.run('whoami', ['/groups'], runInShell: false);
      return r.stdout.toString().contains('S-1-16-12288');
    } catch (_) {
      return false;
    }
  }

  // ── Registration ─────────────────────────────────────────────────────────────

  /// Registers the scheduled task.  Triggers a UAC prompt **exactly once**.
  ///
  /// Throws a descriptive [Exception] on failure, including the actual
  /// PowerShell error message when task creation itself fails.
  static Future<void> register() async {
    if (!Platform.isWindows) return;

    final exePath = Platform.resolvedExecutable;
    final tmp = Directory.systemTemp.path;
    final ps1Path = '$tmp\\tt_register.ps1';
    final vbsPath = '$tmp\\tt_elevate.vbs';
    final statusPath = '$tmp\\tt_status.txt';

    // Remove any stale status file from a previous attempt.
    try {
      await File(statusPath).delete();
    } catch (_) {}

    // ── Step 1: PowerShell script ─────────────────────────────────────────────
    //
    // Uses Register-ScheduledTask cmdlets (no XML, no encoding issues).
    // Writes "OK" on success or the exception message on failure so Dart can
    // read the result without needing a return code from a fire-and-forget
    // ShellExecute call.
    //
    // Escape single-quotes in paths for PowerShell single-quoted strings.
    final exePs = exePath.replaceAll("'", "''");
    final statusPs = statusPath.replaceAll("'", "''");

    final ps1 = StringBuffer()
      ..writeln('try {')
      ..writeln("  \$action = New-ScheduledTaskAction -Execute '$exePs'")
      // Single-line: no backtick line-continuation, no quoting surprises.
      // $principal / $settings use r'...' so Dart doesn't interpolate '$'.
      ..writeln(r'  $principal = New-ScheduledTaskPrincipal'
          r' -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)'
          r' -LogonType Interactive -RunLevel Highest')
      ..writeln(r'  $settings = New-ScheduledTaskSettingsSet'
          r' -MultipleInstances IgnoreNew'
          r' -ExecutionTimeLimit ([TimeSpan]::Zero)'
          r' -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries')
      ..writeln("  Register-ScheduledTask -TaskName '$_taskName'"
          r' -Action $action -Principal $principal -Settings $settings'
          r' -Force | Out-Null')
      ..writeln("  'OK' | Out-File -FilePath '$statusPs' -Encoding UTF8")
      ..writeln('} catch {')
      ..writeln(
          "  \$_.Exception.Message | Out-File -FilePath '$statusPs' -Encoding UTF8")
      ..writeln('}');

    await File(ps1Path).writeAsString(ps1.toString());

    // ── Step 2: VBScript elevator ─────────────────────────────────────────────
    //
    // Shell.Application.ShellExecute with "runas" is the most reliable way to
    // trigger a UAC prompt from an unprivileged process.  PowerShell is given
    // -ExecutionPolicy Bypass so execution-policy settings can't block it.
    // -WindowStyle Hidden prevents a console window from flashing.
    final ps1Q = ps1Path.replaceAll('"', '""'); // VBScript "" = literal "
    final vbs = StringBuffer()
      ..writeln('Set sh = CreateObject("Shell.Application")')
      ..write('sh.ShellExecute "powershell.exe", ')
      ..write(
          '"-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$ps1Q""", ')
      ..writeln('"", "runas", 0'); // 0 = hidden window (SW_HIDE)

    await File(vbsPath).writeAsString(vbs.toString());

    // ── Step 3: fire wscript ──────────────────────────────────────────────────
    //
    // wscript returns immediately after handing off to ShellExecute.
    // The UAC dialog appears asynchronously via consent.exe.
    await Process.run('wscript', ['/nologo', vbsPath], runInShell: false)
        .catchError((_) => ProcessResult(0, 0, '', ''));

    // ── Step 4: poll for the status file (up to 30 s) ────────────────────────
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(milliseconds: 500));

      final sf = File(statusPath);
      if (await sf.exists()) {
        final status = (await sf.readAsString()).trim();
        _deleteFiles([ps1Path, vbsPath, statusPath]);

        if (status == 'OK') return; // ✓ success

        // PowerShell reported an error — show the real message.
        throw Exception('Task Scheduler reported an error:\n\n$status');
      }
    }

    _deleteFiles([ps1Path, vbsPath, statusPath]);
    throw Exception(
      'No response after 30 seconds.\n\n'
      'Possible causes:\n'
      '  • You clicked "No" (or dismissed) the UAC prompt.\n'
      '  • UAC is fully disabled by Group Policy.\n'
      '  • Windows Script Host (wscript.exe) is blocked by policy.\n\n'
      'Workaround: run TrustTunnel as Administrator once, '
      'then retry from Settings.',
    );
  }

  // ── Unregistration ───────────────────────────────────────────────────────────

  /// Removes the scheduled task.  Triggers a UAC prompt once.
  static Future<void> unregister() async {
    if (!Platform.isWindows) return;

    final tmp = Directory.systemTemp.path;
    final vbsPath = '$tmp\\tt_unreg.vbs';

    final vbs = StringBuffer()
      ..writeln('Set sh = CreateObject("Shell.Application")')
      ..write('sh.ShellExecute "schtasks.exe", ')
      ..write('"/delete /tn ""$_taskName"" /f", ')
      ..writeln('"", "runas", 0');

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

  /// Fires the scheduled task (elevated, no UAC) and exits the current process.
  static Future<void> relaunchElevated() async {
    await Process.run(
      'schtasks',
      ['/run', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));

    // Give Task Scheduler a moment to open the elevated window before we close.
    await Future.delayed(const Duration(milliseconds: 800));
    exit(0);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  static void _deleteFiles(List<String> paths) {
    for (final p in paths) {
      File(p).delete().catchError((_) => File(p));
    }
  }
}
