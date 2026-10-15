import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'ble_iot_service.dart';

class BleProvisioningSheet extends StatefulWidget {
  const BleProvisioningSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.62),
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => const BleProvisioningSheet(),
    );
  }

  @override
  State<BleProvisioningSheet> createState() => _BleProvisioningSheetState();
}

class _BleProvisioningSheetState extends State<BleProvisioningSheet> {
  final BleIotService _bleService = BleIotService();
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _isSendingWifi = false;
  String? _feedback;
  bool _feedbackIsError = false;

  @override
  void initState() {
    super.initState();
    _bleService.addListener(_onBleUpdate);
    if (_bleService.connectionState != BleDeviceConnectionState.connected) {
      _bleService.startScan();
    }
    final ssid = _bleService.connectedWifiSsid;
    if (ssid != null) {
      _ssidController.text = ssid;
    }
  }

  @override
  void dispose() {
    _bleService.removeListener(_onBleUpdate);
    _ssidController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _onBleUpdate() {
    if (mounted) setState(() {});
  }

  void _setFeedback(String message, {bool error = false}) {
    setState(() {
      _feedback = message;
      _feedbackIsError = error;
    });
  }

  Future<void> _connectTo(DiscoveredIotDevice item) async {
    setState(() => _feedback = null);
    final success = await _bleService.connectToDevice(item.device);
    if (!mounted) return;
    if (success) {
      _setFeedback('Terhubung ke ${item.name}.');
    } else {
      _setFeedback('Gagal menghubungkan ke ${item.name}.', error: true);
    }
  }

  Future<void> _sendWifiConfig() async {
    final ssid = _ssidController.text.trim();
    final password = _passwordController.text;

    if (ssid.isEmpty) {
      _setFeedback('Nama Wi-Fi (SSID) tidak boleh kosong.', error: true);
      return;
    }

    setState(() {
      _isSendingWifi = true;
      _feedback = null;
    });
    final success = await _bleService.sendWifiCredentials(
      ssid: ssid,
      password: password,
    );
    if (!mounted) return;
    setState(() => _isSendingWifi = false);

    if (success) {
      _setFeedback('Kredensial Wi-Fi terkirim. Menunggu perangkat tersambung…');
    } else {
      _setFeedback('Gagal mengirim kredensial melalui BLE.', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final connected =
        _bleService.connectionState == BleDeviceConnectionState.connected;
    final connecting =
        _bleService.connectionState == BleDeviceConnectionState.connecting;
    final media = MediaQuery.of(context);

    return Container(
      height: media.size.height * 0.9,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        border: Border(top: BorderSide(color: AppColors.borderStrong)),
      ),
      child: Column(
        children: [
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.borderStrong,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 12, 14),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hubungkan perangkat',
                        style: TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        'Pairing via Bluetooth, lalu atur jaringan Wi-Fi.',
                        style: TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close_rounded, size: 20),
                  color: AppColors.textSecondary,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                20,
                20,
                24 + media.viewInsets.bottom,
              ),
              children: [
                _buildSummary(connected, connecting),
                const SizedBox(height: 28),
                _buildDeviceSection(connected, connecting),
                const SizedBox(height: 28),
                _buildWifiSection(connected),
                if (_feedback != null) ...[
                  const SizedBox(height: 18),
                  _buildFeedback(),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(bool connected, bool connecting) {
    final color = connected
        ? AppColors.quiet
        : (connecting ? AppColors.normal : AppColors.textMuted);
    final device = _bleService.connectedDevice;
    final name = device != null && device.platformName.isNotEmpty
        ? device.platformName
        : 'Perangkat IoT';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: panelDecoration(radius: 16, color: AppColors.background),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: connected || connecting
                  ? [BoxShadow(color: color.withValues(alpha: 0.55), blurRadius: 9)]
                  : null,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  connected
                      ? name
                      : (connecting ? 'Menghubungkan…' : 'Belum ada perangkat'),
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  connected
                      ? 'Wi-Fi: ${_bleService.iotWifiStatus}'
                      : 'Pindai lalu pilih perangkat di bawah',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            TextButton(
              onPressed: _bleService.disconnect,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.loud,
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: const Text(
                'Putuskan',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String index, String title, {Widget? trailing}) {
    return Row(
      children: [
        Text(
          index,
          style: AppText.number(
            12,
            color: AppColors.textMuted,
            weight: FontWeight.w500,
          ).copyWith(letterSpacing: 0.5),
        ),
        const SizedBox(width: 10),
        Text(title, style: AppText.label.copyWith(color: AppColors.textSecondary)),
        const Spacer(),
        ?trailing,
      ],
    );
  }

  Widget _buildDeviceSection(bool connected, bool connecting) {
    final devices = _bleService.discoveredDevices;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          '01',
          'PERANGKAT SEKITAR',
          trailing: _bleService.isScanning
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              : InkWell(
                  onTap: _bleService.startScan,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: Row(
                      children: [
                        Icon(
                          Icons.refresh_rounded,
                          size: 15,
                          color: AppColors.textSecondary,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Pindai ulang',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
        const SizedBox(height: 12),
        if (devices.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 20),
            decoration: panelDecoration(radius: 16, color: AppColors.background),
            child: Column(
              children: [
                Icon(
                  _bleService.isScanning
                      ? Icons.radar_rounded
                      : Icons.bluetooth_searching_rounded,
                  size: 26,
                  color: AppColors.textMuted,
                ),
                const SizedBox(height: 12),
                Text(
                  _bleService.isScanning
                      ? 'Mencari perangkat…'
                      : 'Belum ada perangkat terdeteksi',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Pastikan Bluetooth aktif dan perangkat dalam mode pairing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: () {
                    _bleService.connectDemoDevice();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.bolt_rounded, size: 16, color: AppColors.quiet),
                  label: const Text('Pair Perangkat Demo (Tes Refresh 2 Detik)'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.textPrimary,
                    side: const BorderSide(color: AppColors.borderStrong),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Container(
            decoration: panelDecoration(radius: 16, color: AppColors.background),
            clipBehavior: Clip.antiAlias,
            child: ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: devices.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.border),
              itemBuilder: (context, index) =>
                  _buildDeviceRow(devices[index], connecting),
            ),
          ),
      ],
    );
  }

  Widget _buildDeviceRow(DiscoveredIotDevice item, bool connecting) {
    final isCurrent = _bleService.connectedDevice?.remoteId == item.device.remoteId &&
        _bleService.connectionState == BleDeviceConnectionState.connected;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.border),
            ),
            child: Icon(
              Icons.memory_rounded,
              size: 18,
              color: isCurrent ? AppColors.quiet : AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${item.rssi} dBm · ${item.device.remoteId.str}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 11.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          if (isCurrent)
            const Text(
              'Tersambung',
              style: TextStyle(
                color: AppColors.quiet,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            )
          else
            OutlinedButton(
              onPressed: connecting ? null : () => _connectTo(item),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.textPrimary,
                disabledForegroundColor: AppColors.textMuted,
                side: const BorderSide(color: AppColors.borderStrong),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                minimumSize: const Size(0, 34),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: const Text(
                'Hubungkan',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String label, IconData icon, {Widget? suffix}) {
    OutlineInputBorder border(Color color) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(13),
          borderSide: BorderSide(color: color),
        );

    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: AppColors.textMuted, fontSize: 13.5),
      floatingLabelStyle: const TextStyle(
        color: AppColors.textSecondary,
        fontSize: 12.5,
      ),
      prefixIcon: Icon(icon, size: 19, color: AppColors.textMuted),
      suffixIcon: suffix,
      filled: true,
      fillColor: AppColors.background,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      border: border(AppColors.border),
      enabledBorder: border(AppColors.border),
      disabledBorder: border(AppColors.border),
      focusedBorder: border(AppColors.textSecondary),
    );
  }

  Widget _buildWifiSection(bool connected) {
    final canSend = connected && !_isSendingWifi;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader('02', 'JARINGAN WI-FI'),
        const SizedBox(height: 8),
        const Text(
          'Kredensial dikirim ke perangkat melalui koneksi Bluetooth.',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12.5),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _ssidController,
          enabled: connected,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
          decoration: _fieldDecoration('Nama Wi-Fi (SSID)', Icons.wifi_rounded),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passwordController,
          enabled: connected,
          obscureText: _obscurePassword,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14.5),
          decoration: _fieldDecoration(
            'Kata sandi',
            Icons.lock_outline_rounded,
            suffix: IconButton(
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
              icon: Icon(
                _obscurePassword
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                size: 19,
                color: AppColors.textMuted,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 50,
          child: FilledButton(
            onPressed: canSend ? _sendWifiConfig : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.textPrimary,
              foregroundColor: AppColors.background,
              disabledBackgroundColor: AppColors.surfaceRaised,
              disabledForegroundColor: AppColors.textMuted,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: _isSendingWifi
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.background,
                    ),
                  )
                : const Text(
                    'Kirim ke perangkat',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                  ),
          ),
        ),
        if (!connected) ...[
          const SizedBox(height: 12),
          const Text(
            'Hubungkan perangkat via Bluetooth terlebih dahulu.',
            style: TextStyle(color: AppColors.normal, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildFeedback() {
    final color = _feedbackIsError ? AppColors.loud : AppColors.quiet;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _feedback!,
              style: TextStyle(color: color, fontSize: 12.5, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}
