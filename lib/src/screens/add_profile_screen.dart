import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';

import '../theme/app_theme.dart';
import '../models/profile.dart';
import '../providers/profiles_provider.dart';
import '../services/deeplink_service.dart';
import '../services/yaml_service.dart';
import '../services/toml_service.dart';
import '../widgets/gradient_button.dart';
import '../widgets/neon_card.dart';

class AddProfileScreen extends ConsumerStatefulWidget {
  const AddProfileScreen({super.key, this.existingProfile});

  final TrustTunnelProfile? existingProfile;

  @override
  ConsumerState<AddProfileScreen> createState() => _AddProfileScreenState();
}

class _AddProfileScreenState extends ConsumerState<AddProfileScreen>
    with SingleTickerProviderStateMixin {
  // ── Tab controller ──────────────────────────────────────────────────────────
  late final TabController _tabController;

  // ── Form key ────────────────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();

  // ── Text controllers (manual tab) ───────────────────────────────────────────
  final _nameController = TextEditingController();
  final _hostnameController = TextEditingController();
  final _addressesController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _dnsController = TextEditingController();
  final _certController = TextEditingController();
  final _exclusionsController = TextEditingController();
  late final TextEditingController _dnsRoutesController =
      TextEditingController();
  final _socks5AddressController =
      TextEditingController(text: '127.0.0.1:1080');
  final _socks5UserController = TextEditingController();
  final _socks5PassController = TextEditingController();

  // ── Text controller (link/file tab) ─────────────────────────────────────────
  final _linkController = TextEditingController();

  // ── State variables ─────────────────────────────────────────────────────────
  String _selectedProtocol = 'http2';
  String _vpnMode = 'general';
  ListenerType _listenerType = ListenerType.tun;
  bool _antiDpi = false;
  bool _killswitch = true;
  bool _skipVerification = false;
  bool _hasIpv6 = true;
  bool _obscurePassword = true;

  TrustTunnelProfile? _parsedProfile;
  String? _parseError;

  bool get _isEditMode => widget.existingProfile != null;

  // ── Lifecycle ────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    if (_isEditMode) {
      _populateFormFromProfile(widget.existingProfile!);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _nameController.dispose();
    _hostnameController.dispose();
    _addressesController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _dnsController.dispose();
    _certController.dispose();
    _exclusionsController.dispose();
    _dnsRoutesController.dispose();
    _socks5AddressController.dispose();
    _socks5UserController.dispose();
    _socks5PassController.dispose();
    _linkController.dispose();
    super.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  void _populateFormFromProfile(TrustTunnelProfile p) {
    _nameController.text = p.name;
    _hostnameController.text = p.hostname;
    _addressesController.text = p.addresses.join('\n');
    _usernameController.text = p.username;
    _passwordController.text = p.password;
    _dnsController.text = p.dnsUpstreams.join('\n');
    _certController.text = p.certificate;
    _exclusionsController.text = p.exclusions.join('\n');
    _dnsRoutesController.text = p.dnsRouteRules.join('\n');
    _socks5AddressController.text =
        p.socks5Address.isEmpty ? '127.0.0.1:1080' : p.socks5Address;
    _socks5UserController.text = p.socks5Username;
    _socks5PassController.text = p.socks5Password;
    setState(() {
      _selectedProtocol = p.upstreamProtocol;
      _vpnMode = p.vpnMode;
      _listenerType = p.listenerType;
      _antiDpi = p.antiDpi;
      _killswitch = p.killswitchEnabled;
      _skipVerification = p.skipVerification;
      _hasIpv6 = p.hasIpv6;
    });
  }

  void _parseLink() {
    final text = _linkController.text.trim();
    setState(() {
      _parseError = null;
      _parsedProfile = null;
    });
    TrustTunnelProfile? p;
    if (text.startsWith('tt://')) {
      p = DeepLinkService.parseDeepLink(text, const Uuid().v4());
      if (p == null) setState(() => _parseError = 'Failed to parse deep link');
    } else {
      p = TomlService.parseToml(text, const Uuid().v4());
      if (p == null) {
        setState(() => _parseError = 'Failed to parse TOML config');
      }
    }
    if (p != null) {
      setState(() => _parsedProfile = p);
      _populateFormFromProfile(p);
      _tabController.animateTo(0);
    }
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['yaml', 'yml'],
      dialogTitle: 'Select TrustTunnel Profile',
    );
    if (result != null && result.files.single.path != null) {
      try {
        final content = await File(result.files.single.path!).readAsString();
        final p = YamlService.profileFromYaml(content, const Uuid().v4());
        setState(() {
          _parsedProfile = p;
          _parseError = null;
        });
        _populateFormFromProfile(p);
        _tabController.animateTo(0);
      } catch (e) {
        setState(() => _parseError = 'Failed to parse YAML: $e');
      }
    }
  }

  Future<void> _saveProfile() async {
    if (!_formKey.currentState!.validate()) return;
    final profile = TrustTunnelProfile(
      id: widget.existingProfile?.id ?? const Uuid().v4(),
      name: _nameController.text.trim(),
      hostname: _hostnameController.text.trim(),
      addresses: _addressesController.text
          .trim()
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      username: _usernameController.text.trim(),
      password: _passwordController.text,
      dnsUpstreams: _dnsController.text
          .trim()
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      upstreamProtocol: _selectedProtocol,
      vpnMode: _vpnMode,
      listenerType: _listenerType,
      socks5Address: _socks5AddressController.text.trim().isEmpty
          ? '127.0.0.1:1080'
          : _socks5AddressController.text.trim(),
      socks5Username: _socks5UserController.text.trim(),
      socks5Password: _socks5PassController.text,
      certificate: _certController.text.trim(),
      antiDpi: _antiDpi,
      killswitchEnabled: _killswitch,
      skipVerification: _skipVerification,
      hasIpv6: _hasIpv6,
      exclusions: _exclusionsController.text
          .trim()
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
      dnsRouteRules: _dnsRoutesController.text
          .trim()
          .split('\n')
          .where((s) => s.isNotEmpty)
          .toList(),
    );
    if (_isEditMode) {
      await ref.read(profilesProvider.notifier).updateProfile(profile);
    } else {
      await ref.read(profilesProvider.notifier).addProfile(profile);
    }
    if (mounted) Navigator.pop(context);
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(_isEditMode ? 'Edit Profile' : 'Add Profile'),
        backgroundColor: AppTheme.surface,
        foregroundColor: AppTheme.textPrimary,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [
            Tab(text: 'Manual'),
            Tab(text: 'From Link'),
            Tab(text: 'From File'),
          ],
        ),
      ),
      body: Column(
        children: [
          // ── Tab content ──────────────────────────────────────────────────
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildManualTab(),
                _buildFromLinkTab(),
                _buildFromFileTab(),
              ],
            ),
          ),

          // ── Bottom action bar ────────────────────────────────────────────
          _buildBottomBar(),
        ],
      ),
    );
  }

  // ── Manual tab ───────────────────────────────────────────────────────────────

  Widget _buildManualTab() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          // Profile Name
          _buildSectionLabel('Basic Info'),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _nameController,
            label: 'Profile Name*',
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'Profile name is required'
                : null,
          ),
          const SizedBox(height: 16),

          // Hostname
          _buildTextField(
            controller: _hostnameController,
            label: 'Server Hostname*',
            hint: 'vpn.example.com',
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Hostname is required' : null,
          ),
          const SizedBox(height: 16),

          // Addresses
          _buildTextField(
            controller: _addressesController,
            label: 'Addresses (one per line)*',
            hint: '1.2.3.4:443',
            maxLines: 3,
            validator: (v) => (v == null || v.trim().isEmpty)
                ? 'At least one address is required'
                : null,
          ),
          const SizedBox(height: 24),

          // Credentials
          _buildSectionLabel('Credentials'),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _usernameController,
            label: 'Username*',
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Username is required' : null,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            controller: _passwordController,
            label: 'Password*',
            obscureText: _obscurePassword,
            validator: (v) =>
                (v == null || v.isEmpty) ? 'Password is required' : null,
            suffixIcon: IconButton(
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_outlined
                    : Icons.visibility_off_outlined,
                color: AppTheme.textSecondary,
              ),
              onPressed: () =>
                  setState(() => _obscurePassword = !_obscurePassword),
            ),
          ),
          const SizedBox(height: 24),

          // DNS + Protocol
          _buildSectionLabel('Network'),
          const SizedBox(height: 8),
          _buildTextField(
            controller: _dnsController,
            label: 'DNS Upstreams (one per line)',
            hint: 'tls://1.1.1.1',
            maxLines: 2,
          ),
          const SizedBox(height: 16),

          // Upstream Protocol
          DropdownButtonFormField<String>(
            initialValue: _selectedProtocol,
            dropdownColor: AppTheme.card,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: _inputDecoration('Upstream Protocol'),
            items: const [
              DropdownMenuItem(value: 'http2', child: Text('HTTP/2')),
              DropdownMenuItem(value: 'http3', child: Text('HTTP/3 (QUIC)')),
            ],
            onChanged: (v) => setState(() => _selectedProtocol = v!),
          ),
          const SizedBox(height: 24),

          // VPN Mode
          _buildSectionLabel('VPN Mode'),
          const SizedBox(height: 8),
          _buildSegmentedChoice<String>(
            options: const ['general', 'selective'],
            labels: const [
              'General (route all)',
              'Selective (route specified)'
            ],
            selected: _vpnMode,
            onSelected: (v) => setState(() => _vpnMode = v),
          ),
          const SizedBox(height: 24),

          // Listener Type
          _buildSectionLabel('Listener Type'),
          const SizedBox(height: 8),
          _buildSegmentedChoice<ListenerType>(
            options: ListenerType.values,
            labels: ListenerType.values.map((t) => t.label).toList(),
            selected: _listenerType,
            onSelected: (v) => setState(() => _listenerType = v),
          ),

          // SOCKS5 fields (conditional)
          if (_listenerType == ListenerType.socks5) ...[
            const SizedBox(height: 16),
            _buildTextField(
              controller: _socks5AddressController,
              label: 'SOCKS5 Address',
              hint: '127.0.0.1:1080',
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _socks5UserController,
              label: 'SOCKS5 Username (optional)',
            ),
            const SizedBox(height: 16),
            _buildTextField(
              controller: _socks5PassController,
              label: 'SOCKS5 Password (optional)',
              obscureText: true,
            ),
          ],
          const SizedBox(height: 24),

          // Advanced section
          Theme(
            data: Theme.of(context).copyWith(
              dividerColor: Colors.transparent,
            ),
            child: ExpansionTile(
              title: _buildSectionLabel('Advanced', margin: EdgeInsets.zero),
              iconColor: AppTheme.textSecondary,
              collapsedIconColor: AppTheme.textSecondary,
              tilePadding: EdgeInsets.zero,
              childrenPadding: EdgeInsets.zero,
              children: [
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _certController,
                  label: 'TLS Certificate (PEM, leave empty for system CA)',
                  maxLines: 5,
                  hint: '-----BEGIN CERTIFICATE-----\n...',
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  title: const Text(
                    'Anti-DPI',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: const Text(
                    'Obfuscate traffic patterns',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  value: _antiDpi,
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _antiDpi = v),
                ),
                SwitchListTile(
                  title: const Text(
                    'Kill Switch',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: const Text(
                    'Block traffic when VPN disconnects',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  value: _killswitch,
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _killswitch = v),
                ),
                SwitchListTile(
                  title: const Text(
                    'Skip TLS Verification',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: const Text(
                    'Disable certificate verification (insecure)',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  value: _skipVerification,
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _skipVerification = v),
                ),
                SwitchListTile(
                  title: const Text(
                    'IPv6 Support',
                    style: TextStyle(color: AppTheme.textPrimary),
                  ),
                  subtitle: const Text(
                    'Enable IPv6 routing',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                  value: _hasIpv6,
                  activeThumbColor: AppTheme.primary,
                  contentPadding: EdgeInsets.zero,
                  onChanged: (v) => setState(() => _hasIpv6 = v),
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _exclusionsController,
                  label: 'Exclusions (one per line)',
                  hint: '192.168.0.0/16',
                  maxLines: 3,
                ),
                const SizedBox(height: 8),
                _buildTextField(
                  controller: _dnsRoutesController,
                  label: 'DNS Route Rules (one per line)',
                  hint: 'domain:example.com\ncidr:192.168.0.0/16\ngeoip:RU',
                  maxLines: 5,
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ── From Link tab ─────────────────────────────────────────────────────────────

  Widget _buildFromLinkTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Paste a tt:// deep link or TOML config',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        TextFormField(
          controller: _linkController,
          maxLines: 6,
          style: const TextStyle(
              color: AppTheme.textPrimary, fontFamily: 'monospace'),
          decoration: _inputDecoration('Link or TOML config'),
        ),
        const SizedBox(height: 16),
        GradientButton(
          label: 'Parse',
          icon: Icons.search_rounded,
          onPressed: _parseLink,
          width: 120,
        ),
        if (_parseError != null) ...[
          const SizedBox(height: 12),
          Text(
            _parseError!,
            style: const TextStyle(color: AppTheme.error, fontSize: 13),
          ),
        ],
        if (_parsedProfile != null) ...[
          const SizedBox(height: 16),
          _ProfilePreviewCard(profile: _parsedProfile!),
        ],
      ],
    );
  }

  // ── From File tab ─────────────────────────────────────────────────────────────

  Widget _buildFromFileTab() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Import a YAML profile file',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        GradientButton(
          label: 'Pick YAML File',
          icon: Icons.folder_open_rounded,
          onPressed: _pickFile,
          width: 180,
        ),
        if (_parseError != null) ...[
          const SizedBox(height: 12),
          Text(
            _parseError!,
            style: const TextStyle(color: AppTheme.error, fontSize: 13),
          ),
        ],
        if (_parsedProfile != null) ...[
          const SizedBox(height: 16),
          _ProfilePreviewCard(profile: _parsedProfile!),
        ],
      ],
    );
  }

  // ── Bottom action bar ─────────────────────────────────────────────────────────

  Widget _buildBottomBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          top: BorderSide(color: AppTheme.border),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          const SizedBox(width: 12),
          GradientButton(
            label: _isEditMode ? 'Save Changes' : 'Add Profile',
            icon: Icons.check_rounded,
            onPressed: _saveProfile,
            width: 160,
            height: 44,
          ),
        ],
      ),
    );
  }

  // ── Shared UI helpers ─────────────────────────────────────────────────────────

  InputDecoration _inputDecoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: AppTheme.card,
      labelStyle: const TextStyle(color: AppTheme.textSecondary),
      hintStyle:
          TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.5)),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.primary),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppTheme.error),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLines = 1,
    bool obscureText = false,
    String? Function(String?)? validator,
    Widget? suffixIcon,
  }) {
    return TextFormField(
      controller: controller,
      maxLines: obscureText ? 1 : maxLines,
      obscureText: obscureText,
      style: const TextStyle(color: AppTheme.textPrimary),
      validator: validator,
      decoration: _inputDecoration(label, hint: hint).copyWith(
        suffixIcon: suffixIcon,
      ),
    );
  }

  Widget _buildSectionLabel(String text, {EdgeInsets? margin}) {
    return Padding(
      padding: margin ?? const EdgeInsets.only(bottom: 0),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
          color: AppTheme.textSecondary,
        ),
      ),
    );
  }

  Widget _buildSegmentedChoice<T>({
    required List<T> options,
    required List<String> labels,
    required T selected,
    required ValueChanged<T> onSelected,
  }) {
    return Row(
      children: List.generate(options.length, (i) {
        final isSelected = options[i] == selected;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < options.length - 1 ? 8 : 0),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onSelected(options[i]),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                padding:
                    const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.primary.withValues(alpha: 0.15)
                      : AppTheme.card,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? AppTheme.primary : AppTheme.border,
                    width: isSelected ? 1.5 : 1,
                  ),
                ),
                child: Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color:
                        isSelected ? AppTheme.primary : AppTheme.textSecondary,
                    fontWeight:
                        isSelected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

// ── Profile preview card ──────────────────────────────────────────────────────

class _ProfilePreviewCard extends StatelessWidget {
  const _ProfilePreviewCard({required this.profile});

  final TrustTunnelProfile profile;

  @override
  Widget build(BuildContext context) {
    return NeonCard(
      glowColor: AppTheme.success,
      glowing: true,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              color: AppTheme.success,
              size: 22,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile parsed successfully',
                  style: const TextStyle(
                    color: AppTheme.success,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.name}  ·  ${profile.hostname}',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                  ),
                ),
                if (profile.addresses.isNotEmpty)
                  Text(
                    profile.addresses.first,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
