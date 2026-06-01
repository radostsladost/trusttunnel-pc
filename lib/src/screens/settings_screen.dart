import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../theme/app_theme.dart';
import '../models/proxy_config.dart';
import '../providers/connection_provider.dart';
import '../providers/installer_provider.dart';
import '../providers/proxy_provider.dart';
import '../services/autostart_service.dart';
import '../services/installer_service.dart';
import '../services/storage_service.dart';
import '../widgets/neon_card.dart';
import '../widgets/gradient_button.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Proxy form controllers — initialised in didChangeDependencies so they
  // always reflect the persisted state.
  late final TextEditingController _proxyHostCtrl;
  late final TextEditingController _proxyPortCtrl;
  late final TextEditingController _proxyUserCtrl;
  late final TextEditingController _proxyPassCtrl;
  bool _proxyControllersInitialized = false;

  bool _autostartEnabled = false;
  bool _autoConnectEnabled = false;
  String? _globalRoutesFile;
  bool _settingsLoaded = false;

  @override
  void dispose() {
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    _proxyUserCtrl.dispose();
    _proxyPassCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadExtraSettings();
  }

  Future<void> _loadExtraSettings() async {
    final autostart = await AutostartService.isEnabled();
    final autoConnect = await StorageService.loadAutoConnect();
    final routesFile = await StorageService.loadGlobalRoutesFile();
    if (mounted) {
      setState(() {
        _autostartEnabled = autostart;
        _autoConnectEnabled = autoConnect;
        _globalRoutesFile = routesFile;
        _settingsLoaded = true;
      });
    }
  }

  void _initProxyControllers(ProxyConfig config) {
    if (_proxyControllersInitialized) return;
    _proxyHostCtrl = TextEditingController(text: config.host);
    _proxyPortCtrl = TextEditingController(text: config.port.toString());
    _proxyUserCtrl = TextEditingController(text: config.username);
    _proxyPassCtrl = TextEditingController(text: config.password);
    _proxyControllersInitialized = true;
  }

  @override
  Widget build(BuildContext context) {
    final binaryPath = ref.watch(clientBinaryPathProvider);
    final installState = ref.watch(installerProvider);
    final proxyConfig = ref.watch(proxyConfigProvider);

    // Lazily initialise text controllers once the first real value is known.
    _initProxyControllers(proxyConfig);

    // Fall back to the platform default when the path hasn't been set yet.
    final displayPath = binaryPath.isNotEmpty
        ? binaryPath
        : InstallerService.getDefaultBinaryPath();

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ────────────────────────────────────────────────────
            const Text(
              'Settings',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),

            const SizedBox(height: 24),

            // ── Client Binary section ──────────────────────────────────────
            NeonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'CLIENT BINARY',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Current path
                  Row(
                    children: [
                      const Icon(
                        Icons.folder_rounded,
                        color: AppTheme.textSecondary,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          displayPath,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Browse + Reset
                  Row(
                    children: [
                      GradientButton(
                        label: 'Browse...',
                        icon: Icons.folder_open_rounded,
                        height: 40,
                        width: 140,
                        onPressed: () => _pickBinary(ref),
                      ),
                      const SizedBox(width: 12),
                      TextButton(
                        onPressed: () => ref
                            .read(clientBinaryPathProvider.notifier)
                            .updatePath(
                                InstallerService.getDefaultBinaryPath()),
                        child: const Text(
                          'Reset to Default',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // Install status
                  Row(
                    children: [
                      Icon(
                        installState.isInstalled
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded,
                        color: installState.isInstalled
                            ? AppTheme.success
                            : AppTheme.error,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        installState.isInstalled
                            ? 'Installed'
                            : 'Not installed',
                        style: TextStyle(
                          color: installState.isInstalled
                              ? AppTheme.success
                              : AppTheme.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Auto-Install section ───────────────────────────────────────
            NeonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AUTO INSTALL TRUSTTUNNEL CLIENT',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Downloads and installs the latest CLI client from GitHub releases',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Progress bar (only while installing)
                  if (installState.installing) ...[
                    LinearProgressIndicator(
                      value: installState.progress,
                      color: AppTheme.primary,
                      backgroundColor: AppTheme.border,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Downloading... ${(installState.progress * 100).toStringAsFixed(0)}%',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Error message
                  if (installState.error != null) ...[
                    Text(
                      installState.error!,
                      style: const TextStyle(
                        color: AppTheme.error,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],

                  // Install / Update button
                  GradientButton(
                    label: 'Install / Update',
                    icon: Icons.download_rounded,
                    loading: installState.installing,
                    onPressed: installState.installing
                        ? null
                        : () => ref.read(installerProvider.notifier).install(),
                  ),

                  const SizedBox(height: 12),

                  // Install directory row
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Install to: ${InstallerService.getDefaultInstallDir()}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () => _changeInstallDir(ref),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Change',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Proxy section ──────────────────────────────────────────────
            _ProxyCard(
              config: proxyConfig,
              hostCtrl: _proxyHostCtrl,
              portCtrl: _proxyPortCtrl,
              userCtrl: _proxyUserCtrl,
              passCtrl: _proxyPassCtrl,
              onChanged: (updated) =>
                  ref.read(proxyConfigProvider.notifier).update(updated),
            ),

            const SizedBox(height: 24),

            // ── Autostart section ──────────────────────────────────────────
            NeonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AUTOSTART',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Launch TrustTunnel automatically when you log in',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Launch at startup',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                      Switch(
                        value: _autostartEnabled,
                        activeThumbColor: AppTheme.primary,
                        onChanged: _settingsLoaded
                            ? (v) async {
                                await AutostartService.setEnabled(v);
                                // Turning off autostart also turns off
                                // auto-connect to avoid orphaned setting.
                                if (!v && _autoConnectEnabled) {
                                  await StorageService.saveAutoConnect(false);
                                  setState(() => _autoConnectEnabled = false);
                                }
                                setState(() => _autostartEnabled = v);
                              }
                            : null,
                      ),
                    ],
                  ),

                  // Sub-option: auto-connect (only meaningful when autostart is on)
                  AnimatedCrossFade(
                    duration: const Duration(milliseconds: 200),
                    crossFadeState: _autostartEnabled
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    firstChild: Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              const SizedBox(width: 16),
                              const Icon(Icons.bolt_rounded,
                                  color: AppTheme.textSecondary, size: 16),
                              const SizedBox(width: 8),
                              const Text(
                                'Auto-connect on launch',
                                style: TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                          Switch(
                            value: _autoConnectEnabled,
                            activeThumbColor: AppTheme.secondary,
                            onChanged: _settingsLoaded
                                ? (v) async {
                                    await StorageService.saveAutoConnect(v);
                                    setState(() => _autoConnectEnabled = v);
                                  }
                                : null,
                          ),
                        ],
                      ),
                    ),
                    secondChild: const SizedBox.shrink(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── Global DNS Routes File section ──────────────────────────────
            NeonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'GLOBAL DNS ROUTE RULES FILE',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Plain-text file with one rule per line (domain:, cidr:, geoip: prefixes). '
                    'Rules are merged with per-profile routes at connection time.',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_globalRoutesFile != null &&
                      _globalRoutesFile!.isNotEmpty) ...[
                    Row(
                      children: [
                        const Icon(Icons.insert_drive_file_rounded,
                            color: AppTheme.textSecondary, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _globalRoutesFile!,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        IconButton(
                          onPressed: () async {
                            await StorageService.saveGlobalRoutesFile(null);
                            setState(() => _globalRoutesFile = null);
                          },
                          icon: const Icon(Icons.close_rounded,
                              color: AppTheme.error, size: 16),
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          tooltip: 'Remove file',
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  GradientButton(
                    label: 'Browse…',
                    icon: Icons.folder_open_rounded,
                    height: 40,
                    width: 140,
                    onPressed: () => _pickGlobalRoutesFile(),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            // ── About section ─────────────────────────────────────────────
            NeonCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'TrustTunnel Desktop',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'v1.0.0',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Protocol: TrustTunnel Protocol (by AdGuard)',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text(
                        'https://github.com/TrustTunnel/TrustTunnel',
                        style: TextStyle(
                          color: AppTheme.primary,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        onPressed: () {
                          Clipboard.setData(
                            const ClipboardData(
                              text:
                                  'https://github.com/TrustTunnel/TrustTunnel',
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Link copied to clipboard'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                        icon: const Icon(
                          Icons.copy_rounded,
                          size: 16,
                          color: AppTheme.textSecondary,
                        ),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        tooltip: 'Copy link',
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickGlobalRoutesFile() async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select DNS routes file',
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      await StorageService.saveGlobalRoutesFile(path);
      setState(() => _globalRoutesFile = path);
    }
  }

  // ── Binary picker ─────────────────────────────────────────────────

  Future<void> _pickBinary(WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: 'Select trusttunnel_client binary',
    );
    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      await ref.read(clientBinaryPathProvider.notifier).updatePath(path);
      await ref
          .read(installerProvider.notifier)
          .checkInstalled(customPath: path);
    }
  }

  // ── Install directory picker ───────────────────────────────────────────────

  Future<void> _changeInstallDir(WidgetRef ref) async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: 'Select install directory',
    );
    if (result != null) {
      await ref
          .read(installerProvider.notifier)
          .install(customInstallDir: result);
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Proxy Card
// ─────────────────────────────────────────────────────────────────────────────

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({
    required this.config,
    required this.hostCtrl,
    required this.portCtrl,
    required this.userCtrl,
    required this.passCtrl,
    required this.onChanged,
  });

  final ProxyConfig config;
  final TextEditingController hostCtrl;
  final TextEditingController portCtrl;
  final TextEditingController userCtrl;
  final TextEditingController passCtrl;
  final void Function(ProxyConfig) onChanged;

  static const _fieldDecoration = InputDecoration(
    filled: true,
    fillColor: AppTheme.background,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: AppTheme.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: AppTheme.border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(8)),
      borderSide: BorderSide(color: AppTheme.primary, width: 1.5),
    ),
    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    isDense: true,
  );

  void _save() {
    final port = int.tryParse(portCtrl.text.trim()) ?? config.port;
    onChanged(config.copyWith(
      host: hostCtrl.text.trim().isEmpty ? '127.0.0.1' : hostCtrl.text.trim(),
      port: port,
      username: userCtrl.text.trim(),
      password: passCtrl.text,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      glowColor: config.enabled ? AppTheme.secondary : AppTheme.border,
      glowing: config.enabled,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: title + enable toggle
          Row(
            children: [
              const Icon(Icons.vpn_key_rounded,
                  color: AppTheme.secondary, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'APP OUTBOUND PROXY',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textSecondary,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              Switch(
                value: config.enabled,
                activeThumbColor: AppTheme.secondary,
                onChanged: (v) => onChanged(config.copyWith(enabled: v)),
              ),
            ],
          ),

          const SizedBox(height: 4),
          Text(
            'Routes app HTTP traffic (installer, updates) through your proxy.\n'
            'Required if GitHub is blocked on your network.',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),

          if (config.enabled) ...[
            const SizedBox(height: 16),

            // Type selector
            Row(
              children: [
                const Text('Type: ',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                const SizedBox(width: 8),
                _TypeChip(
                  label: 'SOCKS5',
                  selected: config.type == ProxyType.socks5,
                  onTap: () =>
                      onChanged(config.copyWith(type: ProxyType.socks5)),
                ),
                const SizedBox(width: 8),
                _TypeChip(
                  label: 'HTTP',
                  selected: config.type == ProxyType.http,
                  onTap: () => onChanged(config.copyWith(type: ProxyType.http)),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Host + Port row
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Host',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: hostCtrl,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13),
                        decoration: _fieldDecoration.copyWith(
                            hintText: '127.0.0.1',
                            hintStyle:
                                const TextStyle(color: AppTheme.textSecondary)),
                        onEditingComplete: _save,
                        onSubmitted: (_) => _save(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Port',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: portCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13),
                        decoration: _fieldDecoration.copyWith(
                            hintText: '1080',
                            hintStyle:
                                const TextStyle(color: AppTheme.textSecondary)),
                        onEditingComplete: _save,
                        onSubmitted: (_) => _save(),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Username + Password row (optional)
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Username (optional)',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: userCtrl,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13),
                        decoration: _fieldDecoration,
                        onEditingComplete: _save,
                        onSubmitted: (_) => _save(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Password (optional)',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 12)),
                      const SizedBox(height: 4),
                      TextField(
                        controller: passCtrl,
                        obscureText: true,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13),
                        decoration: _fieldDecoration,
                        onEditingComplete: _save,
                        onSubmitted: (_) => _save(),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Apply button
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.check_rounded,
                    size: 16, color: AppTheme.secondary),
                label: const Text('Apply',
                    style: TextStyle(color: AppTheme.secondary)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.secondary.withValues(alpha: 0.15)
              : AppTheme.card,
          border: Border.all(
            color: selected ? AppTheme.secondary : AppTheme.border,
            width: 1.5,
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppTheme.secondary : AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
