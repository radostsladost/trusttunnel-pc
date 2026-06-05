import 'dart:io';

/// Manages a Windows Task Scheduler task that runs TrustTunnel with
/// `HighestAvailable` privileges — eliminating per-launch UAC prompts.
///
/// ## How it works
///
/// Windows Task Scheduler can run a task elevated on behalf of the current
/// user WITHOUT a UAC prompt, because the privilege is granted once when the
/// task is *registered*.  After registration:
///
///   - `schtasks /run /tn TrustTunnel_Elevated` launches the app elevated.
///   - No UAC dialog appears for the user.
///
/// ## Lifecycle
///
/// 1. [register] — writes a task XML, then starts an elevated PowerShell
///    to call `Register-ScheduledTask`.  UAC appears **once**.
/// 2. From then on, [relaunchElevated] is called whenever TUN mode is
///    requested but the current process is not yet elevated.  It fires
///    `schtasks /run`, waits briefly, and calls `exit(0)` on the current
///    (non-elevated) instance.  The user sees the app reopen immediately,
///    with no UAC prompt.
/// 3. [unregister] — removes the task (UAC appears once to delete it).
class ElevatedTaskService {
  ElevatedTaskService._();

  static const String _taskName = 'TrustTunnel_Elevated';

  // ── Queries ─────────────────────────────────────────────────────────────────

  /// Returns true if the elevated task is registered for this user.
  static Future<bool> isRegistered() async {
    if (!Platform.isWindows) return false;
    final r = await Process.run(
      'schtasks',
      ['/query', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));
    return r.exitCode == 0;
  }

  /// Returns true if the current process is already running as Administrator.
  static Future<bool> isElevated() async {
    if (!Platform.isWindows) return true; // not relevant on other platforms
    final r = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'([Security.Principal.WindowsPrincipal]'
            r'[Security.Principal.WindowsIdentity]::GetCurrent())'
            r'.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)',
      ],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, 'false', ''));
    return r.stdout.toString().trim().toLowerCase() == 'true';
  }

  // ── Registration ─────────────────────────────────────────────────────────────

  /// Registers the scheduled task.  Shows a UAC prompt **once**.
  ///
  /// Throws if the user cancels UAC or if registration fails.
  static Future<void> register() async {
    if (!Platform.isWindows) return;

    final exePath = Platform.resolvedExecutable;
    final tmp = Directory.systemTemp.path;
    final xmlPath = '$tmp\\tt_task.xml';
    final ps1Path = '$tmp\\tt_register.ps1';

    // Write the task XML (UTF-8 is fine for Register-ScheduledTask).
    await File(xmlPath).writeAsString(_buildTaskXml(exePath));

    // Write a small helper script that PowerShell will execute elevated.
    // Using a file avoids quoting nightmares when embedding XML in -Command.
    await File(ps1Path).writeAsString(
      r'$xml = [System.IO.File]::ReadAllText($args[0]);'
      'Register-ScheduledTask -Xml \$xml -TaskName "$_taskName" -Force;',
    );

    // Launch elevated PowerShell (UAC appears once here).
    final result = await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Process powershell '
            '-Verb RunAs '
            '-Wait '
            '-ArgumentList "-NoProfile -NonInteractive -File \\"$ps1Path\\" \\"$xmlPath\\""',
      ],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));

    // Clean up temp files.
    for (final p in [xmlPath, ps1Path]) {
      File(p).delete().catchError((_) => File(p));
    }

    if (result.exitCode != 0) {
      throw Exception(
        'Could not register the elevated task (exit ${result.exitCode}).\n'
        'Make sure you clicked "Yes" in the UAC prompt.',
      );
    }

    // Verify it actually got created.
    if (!await isRegistered()) {
      throw Exception(
        'Task registration appeared to succeed but the task was not found.\n'
        'Try running the app as Administrator once, then set it up again.',
      );
    }
  }

  /// Removes the scheduled task.  Shows a UAC prompt once.
  static Future<void> unregister() async {
    if (!Platform.isWindows) return;
    await Process.run(
      'powershell',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Start-Process schtasks '
            '-Verb RunAs '
            '-Wait '
            '-ArgumentList "/delete /tn $_taskName /f"',
      ],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));
  }

  // ── Relaunch ────────────────────────────────────────────────────────────────

  /// Fires the scheduled task (elevated, no UAC) and exits the current
  /// non-elevated process.
  ///
  /// The user will see the app reopen within ~1 second, already elevated.
  static Future<void> relaunchElevated() async {
    await Process.run(
      'schtasks',
      ['/run', '/tn', _taskName],
      runInShell: false,
    ).catchError((_) => ProcessResult(0, 1, '', ''));

    // Give Task Scheduler a moment to spin up the new instance before we
    // disappear, so there is no visible gap in the app window.
    await Future.delayed(const Duration(milliseconds: 800));
    exit(0);
  }

  // ── XML builder ─────────────────────────────────────────────────────────────

  static String _buildTaskXml(String exePath) {
    // Escape characters that are special in XML.
    final escaped = exePath
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
      <!-- HighestAvailable = Admin if the user is in the Administrators group,
           otherwise standard.  Avoids failures for non-admin accounts. -->
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
      <Command>$escaped</Command>
    </Exec>
  </Actions>
</Task>''';
  }
}
