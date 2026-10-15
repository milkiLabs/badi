import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';
import 'package:layer_shell/layer_shell.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the Wi-Fi popup.
///
/// keyboardMode is onDemand so the password field can receive focus.
const PopupWindowConfig wifiPopupConfig = PopupWindowConfig(
  width: 320,
  height: 440,
  namespace: 'badi-wifi-popup',
  keyboardMode: LayerShellKeyboardMode.onDemand,
);

// ---------------------------------------------------------------------------
// NetworkManager D-Bus names
// ---------------------------------------------------------------------------

const _nmName = 'org.freedesktop.NetworkManager';
const _nmPath = '/org/freedesktop/NetworkManager';
const _nmIface = 'org.freedesktop.NetworkManager';
const _nmSettingsPath = '/org/freedesktop/NetworkManager/Settings';
const _nmSettingsIface = 'org.freedesktop.NetworkManager.Settings';
const _nmConnIface = 'org.freedesktop.NetworkManager.Settings.Connection';
const _nmDeviceIface = 'org.freedesktop.NetworkManager.Device';
const _nmWirelessIface = 'org.freedesktop.NetworkManager.Device.Wireless';
const _nmApIface = 'org.freedesktop.NetworkManager.AccessPoint';

// NMDeviceType
const _deviceTypeWifi = 2;

// NMDeviceState
const _stateDisconnected = 30;
const _statePrepare = 40;
const _stateActivated = 100;
const _stateFailed = 120;

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

enum WifiSecurity { open, wep, psk, sae, enterprise }

class WifiNetwork {
  const WifiNetwork({
    required this.ssid,
    required this.strength,
    required this.security,
    required this.apPath,
    this.savedPath,
    this.isActive = false,
    this.isConnecting = false,
  });

  final String ssid;

  /// Signal strength, 0 to 100.
  final int strength;
  final WifiSecurity security;

  /// Strongest access point object for this SSID.
  final DBusObjectPath apPath;

  /// Saved NetworkManager profile for this SSID, if any.
  final DBusObjectPath? savedPath;
  final bool isActive;
  final bool isConnecting;

  bool get isSaved => savedPath != null;
  bool get isSecured => security != WifiSecurity.open;
}

class _Ap {
  const _Ap(this.path, this.ssid, this.strength, this.security);

  final DBusObjectPath path;
  final String ssid;
  final int strength;
  final WifiSecurity security;
}

/// Picks a Material icon for a signal strength between 0 and 100.
IconData wifiIcon(int strength) {
  if (strength >= 75) return Icons.wifi;
  if (strength >= 50) return Icons.wifi_2_bar;
  return Icons.wifi_1_bar;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Talks to NetworkManager over the system D-Bus. Shared by the popup and by
/// [WifiStatusIcon]. Polling and signal subscriptions only run while at least
/// one widget has called [start] without a matching [stop].
class WifiService extends ChangeNotifier {
  WifiService._();

  static final WifiService instance = WifiService._();

  // Public state.
  bool available = false;
  String? statusMessage = 'Connecting to NetworkManager...';
  bool enabled = false;
  int deviceState = 0;
  String? activeSsid;
  int activeStrength = 0;
  List<WifiNetwork> networks = const [];
  bool scanning = false;
  String? busySsid;
  String? error;

  bool get connected => deviceState == _stateActivated;
  bool get connecting =>
      deviceState >= _statePrepare && deviceState < _stateActivated;

  DBusClient? _client;
  DBusRemoteObject? _nm;
  DBusRemoteObject? _device;
  DBusObjectPath? _devicePath;

  /// Saved Wi-Fi profiles. Value is null for profiles that are not Wi-Fi, so
  /// they are not fetched again on every refresh.
  final Map<DBusObjectPath, String?> _savedSsids = {};

  final List<StreamSubscription<dynamic>> _subs = [];
  bool _subscribed = false;
  int _users = 0;
  Timer? _poll;
  Timer? _debounce;
  Timer? _errorTimer;
  bool _refreshing = false;
  bool _refreshAgain = false;

  void start() {
    if (_users++ > 0) return;
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => refresh());
    refresh();
  }

  void stop() {
    if (--_users > 0) return;
    _users = 0;
    _poll?.cancel();
    _poll = null;
    _debounce?.cancel();
    _unsubscribe();
  }

  void reportError(String message) {
    error = message;
    _errorTimer?.cancel();
    _errorTimer = Timer(const Duration(seconds: 8), () {
      error = null;
      notifyListeners();
    });
    notifyListeners();
  }

  void _clearError() {
    _errorTimer?.cancel();
    error = null;
  }

  // -- Loading ---------------------------------------------------------------

  Future<void> refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        await _load();
      } while (_refreshAgain);
    } finally {
      _refreshing = false;
    }
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), refresh);
  }

  void _setUnavailable(String message) {
    available = false;
    statusMessage = message;
    networks = const [];
    activeSsid = null;
    activeStrength = 0;
    notifyListeners();
  }

  Future<void> _load() async {
    try {
      final client = _client ??= DBusClient.system();
      final nm = _nm ??= DBusRemoteObject(
        client,
        name: _nmName,
        path: DBusObjectPath(_nmPath),
      );

      enabled = (await nm.getProperty(_nmIface, 'WirelessEnabled')).asBoolean();

      if (!await _findDevice(client)) {
        _setUnavailable('No Wi-Fi adapter found');
        return;
      }
      final device = _device!;

      deviceState =
          (await device.getProperty(_nmDeviceIface, 'State')).asUint32();
      available = true;
      statusMessage = null;

      if (!enabled) {
        networks = const [];
        activeSsid = null;
        activeStrength = 0;
        notifyListeners();
        _subscribe();
        return;
      }

      final activePath =
          (await device.getProperty(_nmWirelessIface, 'ActiveAccessPoint'))
              .asObjectPath();
      final activeAp =
          activePath.value == '/' ? null : await _readAp(client, activePath);

      final allPaths = (await device.callMethod(
        _nmWirelessIface,
        'GetAllAccessPoints',
        [],
        replySignature: DBusSignature('ao'),
      ))
          .returnValues[0]
          .asObjectPathArray();
      final aps = (await Future.wait(allPaths.map((p) => _readAp(client, p))))
          .whereType<_Ap>();

      await _refreshSaved(client);

      // Keep the strongest access point per SSID.
      final bySsid = <String, _Ap>{};
      for (final ap in aps) {
        final current = bySsid[ap.ssid];
        if (current == null || ap.strength > current.strength) {
          bySsid[ap.ssid] = ap;
        }
      }
      if (activeAp != null) bySsid[activeAp.ssid] = activeAp;

      final saved = <String, DBusObjectPath>{};
      _savedSsids.forEach((path, ssid) {
        if (ssid != null) saved.putIfAbsent(ssid, () => path);
      });

      final isUp = connected || connecting;
      activeSsid = isUp ? activeAp?.ssid : null;
      activeStrength = activeAp?.strength ?? 0;

      final list = bySsid.values
          .map(
            (ap) => WifiNetwork(
              ssid: ap.ssid,
              strength: ap.strength,
              security: ap.security,
              apPath: ap.path,
              savedPath: saved[ap.ssid],
              isActive: connected && ap.ssid == activeAp?.ssid,
              isConnecting: ap.ssid == busySsid ||
                  (connecting && ap.ssid == activeAp?.ssid),
            ),
          )
          .toList();
      list.sort((a, b) {
        if (a.isActive != b.isActive) return a.isActive ? -1 : 1;
        return b.strength.compareTo(a.strength);
      });
      networks = list;
      notifyListeners();
      _subscribe();
    } catch (_) {
      _devicePath = null;
      _device = null;
      _unsubscribe();
      _setUnavailable('NetworkManager is not available');
    }
  }

  Future<bool> _findDevice(DBusClient client) async {
    if (_devicePath != null) return true;
    final paths =
        (await _nm!.getProperty(_nmIface, 'Devices')).asObjectPathArray();
    for (final path in paths) {
      final obj = DBusRemoteObject(client, name: _nmName, path: path);
      final type =
          (await obj.getProperty(_nmDeviceIface, 'DeviceType')).asUint32();
      if (type == _deviceTypeWifi) {
        _devicePath = path;
        _device = obj;
        return true;
      }
    }
    return false;
  }

  Future<_Ap?> _readAp(DBusClient client, DBusObjectPath path) async {
    try {
      final props = await DBusRemoteObject(client, name: _nmName, path: path)
          .getAllProperties(_nmApIface);
      final ssid = utf8.decode(
        props['Ssid']!.asByteArray().toList(),
        allowMalformed: true,
      );
      if (ssid.isEmpty) return null; // hidden network
      return _Ap(
        path,
        ssid,
        props['Strength']!.asByte(),
        _securityOf(
          props['Flags']!.asUint32(),
          props['WpaFlags']!.asUint32(),
          props['RsnFlags']!.asUint32(),
        ),
      );
    } catch (_) {
      // The access point can disappear between listing and reading.
      return null;
    }
  }

  WifiSecurity _securityOf(int flags, int wpa, int rsn) {
    final both = wpa | rsn;
    if ((both & 0x200) != 0) return WifiSecurity.enterprise; // 802.1X
    if ((both & 0x100) != 0) return WifiSecurity.psk;
    if ((rsn & 0x400) != 0) return WifiSecurity.sae;
    if (both != 0) return WifiSecurity.psk;
    if ((flags & 0x1) != 0) return WifiSecurity.wep;
    return WifiSecurity.open;
  }

  Future<void> _refreshSaved(DBusClient client) async {
    final settings = DBusRemoteObject(
      client,
      name: _nmName,
      path: DBusObjectPath(_nmSettingsPath),
    );
    final paths = (await settings.callMethod(
      _nmSettingsIface,
      'ListConnections',
      [],
      replySignature: DBusSignature('ao'),
    ))
        .returnValues[0]
        .asObjectPathArray()
        .toSet();

    _savedSsids.removeWhere((path, _) => !paths.contains(path));

    final unseen = paths.where((p) => !_savedSsids.containsKey(p));
    await Future.wait(unseen.map((path) async {
      String? ssid;
      try {
        final obj = DBusRemoteObject(client, name: _nmName, path: path);
        final reply = await obj.callMethod(
          _nmConnIface,
          'GetSettings',
          [],
          replySignature: DBusSignature('a{sa{sv}}'),
        );
        for (final entry in reply.returnValues[0].asDict().entries) {
          if (entry.key.asString() == '802-11-wireless') {
            final raw = entry.value.asStringVariantDict()['ssid'];
            if (raw != null) {
              ssid =
                  utf8.decode(raw.asByteArray().toList(), allowMalformed: true);
            }
          }
        }
      } catch (_) {
        ssid = null;
      }
      _savedSsids[path] = ssid;
    }));
  }

  // -- Signals ---------------------------------------------------------------

  void _subscribe() {
    final client = _client;
    final path = _devicePath;
    if (_subscribed || _users == 0 || client == null || path == null) return;
    _subscribed = true;
    _subs.add(_nm!.propertiesChanged.listen((_) => _scheduleRefresh()));
    _subs.add(_device!.propertiesChanged.listen((_) => _scheduleRefresh()));
    // AccessPointAdded and AccessPointRemoved.
    _subs.add(
      DBusSignalStream(
        client,
        sender: _nmName,
        interface: _nmWirelessIface,
        path: path,
      ).listen((_) => _scheduleRefresh()),
    );
  }

  void _unsubscribe() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    _subscribed = false;
  }

  // -- Actions ---------------------------------------------------------------

  Future<void> setEnabled(bool value) async {
    enabled = value;
    notifyListeners();
    try {
      await _nm?.setProperty(_nmIface, 'WirelessEnabled', DBusBoolean(value));
    } catch (e) {
      reportError('Could not change Wi-Fi state');
    }
    await refresh();
  }

  Future<void> requestScan() async {
    final device = _device;
    if (device == null || scanning) return;
    scanning = true;
    notifyListeners();
    try {
      await device.callMethod(
        _nmWirelessIface,
        'RequestScan',
        [DBusDict.stringVariant({})],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      // NetworkManager rejects scans that come too soon after the last one.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    scanning = false;
    await refresh();
  }

  /// Connects to [network]. Saved networks and open networks need no password.
  /// For a new secured network, pass [password].
  Future<void> connect(WifiNetwork network, {String? password}) async {
    final device = _devicePath;
    final nm = _nm;
    if (busySsid != null || device == null || nm == null) return;

    _clearError();
    busySsid = network.ssid;
    notifyListeners();

    DBusObjectPath? created;
    try {
      if (network.savedPath != null) {
        await nm.callMethod(
          _nmIface,
          'ActivateConnection',
          [network.savedPath!, device, network.apPath],
          replySignature: DBusSignature('o'),
          allowInteractiveAuthorization: true,
        );
      } else {
        final reply = await nm.callMethod(
          _nmIface,
          'AddAndActivateConnection',
          [_buildSettings(network, password), device, network.apPath],
          replySignature: DBusSignature('oo'),
          allowInteractiveAuthorization: true,
        );
        created = reply.returnValues[0].asObjectPath();
      }

      final ok = await _waitForActivation(network.ssid);
      if (!ok) {
        if (created != null) await _deleteProfile(created);
        reportError(
          network.isSecured && network.savedPath == null
              ? 'Could not connect. Check the password.'
              : 'Could not connect to ${network.ssid}',
        );
      }
    } catch (e) {
      if (created != null) await _deleteProfile(created);
      reportError(_shorten(e));
    } finally {
      busySsid = null;
      await refresh();
    }
  }

  Future<bool> _waitForActivation(String ssid) async {
    final device = _device;
    if (device == null) return false;
    var sawProgress = false;
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final state =
          (await device.getProperty(_nmDeviceIface, 'State')).asUint32();
      if (state == _stateActivated) {
        if (await _currentSsid() == ssid) return true;
      } else if (state >= _statePrepare && state < _stateActivated) {
        sawProgress = true;
      } else if (sawProgress &&
          (state == _stateDisconnected || state == _stateFailed)) {
        return false;
      }
    }
    return false;
  }

  Future<String?> _currentSsid() async {
    final client = _client;
    final device = _device;
    if (client == null || device == null) return null;
    final path =
        (await device.getProperty(_nmWirelessIface, 'ActiveAccessPoint'))
            .asObjectPath();
    if (path.value == '/') return null;
    return (await _readAp(client, path))?.ssid;
  }

  DBusValue _buildSettings(WifiNetwork network, String? password) {
    final sections = <DBusValue, DBusValue>{
      DBusString('connection'): DBusDict.stringVariant({
        'id': DBusString(network.ssid),
        'type': DBusString('802-11-wireless'),
        'autoconnect': DBusBoolean(true),
      }),
      DBusString('802-11-wireless'): DBusDict.stringVariant({
        'ssid': DBusArray.byte(utf8.encode(network.ssid)),
        'mode': DBusString('infrastructure'),
      }),
    };

    if (network.isSecured && password != null) {
      final keyMgmt = switch (network.security) {
        WifiSecurity.sae => 'sae',
        WifiSecurity.wep => 'none',
        _ => 'wpa-psk',
      };
      final security = <String, DBusValue>{'key-mgmt': DBusString(keyMgmt)};
      if (network.security == WifiSecurity.wep) {
        security['wep-key0'] = DBusString(password);
        security['wep-key-type'] = DBusUint32(1);
      } else {
        security['psk'] = DBusString(password);
      }
      sections[DBusString('802-11-wireless-security')] =
          DBusDict.stringVariant(security);
    }

    return DBusDict(DBusSignature('s'), DBusSignature('a{sv}'), sections);
  }

  Future<void> disconnect() async {
    final device = _device;
    if (device == null) return;
    _clearError();
    try {
      await device.callMethod(
        _nmDeviceIface,
        'Disconnect',
        [],
        replySignature: DBusSignature(''),
        allowInteractiveAuthorization: true,
      );
    } catch (e) {
      reportError(_shorten(e));
    }
    await refresh();
  }

  Future<void> forget(WifiNetwork network) async {
    final path = network.savedPath;
    if (path == null) return;
    _clearError();
    await _deleteProfile(path);
    await refresh();
  }

  Future<void> _deleteProfile(DBusObjectPath path) async {
    final client = _client;
    if (client == null) return;
    try {
      await DBusRemoteObject(client, name: _nmName, path: path).callMethod(
        _nmConnIface,
        'Delete',
        [],
        replySignature: DBusSignature(''),
        allowInteractiveAuthorization: true,
      );
    } catch (_) {
      // Already gone, or not permitted. Nothing useful to do.
    }
    _savedSsids.remove(path);
  }

  /// Opens the full NetworkManager editor for anything the popup cannot do,
  /// such as enterprise networks or static IP setup.
  Future<void> openSettings() async {
    try {
      await Process.start(
        'nm-connection-editor',
        const [],
        mode: ProcessStartMode.detached,
      );
    } catch (_) {
      reportError('Could not launch nm-connection-editor');
    }
  }

  String _shorten(Object e) {
    final text = e.toString();
    return text.length > 80 ? '${text.substring(0, 80)}...' : text;
  }
}

// ---------------------------------------------------------------------------
// Bar icon
// ---------------------------------------------------------------------------

/// Small status icon for the bar. Reflects connection state and signal.
class WifiStatusIcon extends StatefulWidget {
  const WifiStatusIcon({super.key, this.size = 18});

  final double size;

  @override
  State<WifiStatusIcon> createState() => _WifiStatusIconState();
}

class _WifiStatusIconState extends State<WifiStatusIcon> {
  final _service = WifiService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    final IconData icon;
    if (!s.available || !s.enabled) {
      icon = Icons.wifi_off;
    } else if (s.connected) {
      icon = wifiIcon(s.activeStrength);
    } else if (s.connecting) {
      icon = Icons.wifi_find;
    } else {
      icon = Icons.signal_wifi_bad;
    }
    return Icon(icon, size: widget.size);
  }
}

// ---------------------------------------------------------------------------
// Popup content
// ---------------------------------------------------------------------------

const _accent = Colors.lightBlueAccent;

/// Wi-Fi popup content: toggle, scan, network list, connect, disconnect,
/// forget and a shortcut to the full settings editor.
class WifiPopupContent extends StatefulWidget {
  const WifiPopupContent({super.key});

  @override
  State<WifiPopupContent> createState() => _WifiPopupContentState();
}

class _WifiPopupContentState extends State<WifiPopupContent> {
  final _service = WifiService.instance;
  final _passwordController = TextEditingController();
  String? _promptSsid;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.stop();
    _passwordController.dispose();
    super.dispose();
  }

  void _onTap(WifiNetwork network) {
    if (network.isActive || network.isConnecting || _service.busySsid != null) {
      return;
    }
    if (network.isSaved || !network.isSecured) {
      setState(() => _promptSsid = null);
      _service.connect(network);
      return;
    }
    if (network.security == WifiSecurity.enterprise) {
      _service.reportError('Enterprise networks need the Settings editor');
      return;
    }
    setState(() {
      _promptSsid = _promptSsid == network.ssid ? null : network.ssid;
      _passwordController.clear();
      _obscure = true;
    });
  }

  void _submitPassword(WifiNetwork network) {
    final password = _passwordController.text;
    if (password.isEmpty) return;
    if (network.security == WifiSecurity.psk && password.length < 8) {
      _service.reportError('Password must be at least 8 characters');
      return;
    }
    _passwordController.clear();
    setState(() => _promptSsid = null);
    _service.connect(network, password: password);
  }

  @override
  Widget build(BuildContext context) {
    final s = _service;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(s),
        const SizedBox(height: 8),
        Expanded(child: _buildBody(s)),
        if (s.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              s.error!,
              style: AppTextStyles.rowSubtitle.copyWith(
                color: Colors.redAccent,
              ),
            ),
          ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: s.openSettings,
              icon: const Icon(Icons.settings_outlined, size: 16),
              label: const Text('Settings'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildHeader(WifiService s) {
    return Row(
      children: [
        Text('Wi-Fi', style: AppTextStyles.rowTitle),
        const Spacer(),
        if (s.available && s.enabled)
          s.scanning
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  onPressed: s.requestScan,
                  icon: const Icon(Icons.refresh),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Scan',
                ),
        if (s.available) Switch(value: s.enabled, onChanged: s.setEnabled),
      ],
    );
  }

  Widget _buildBody(WifiService s) {
    if (!s.available) {
      return _centerText(s.statusMessage ?? 'Wi-Fi is unavailable');
    }
    if (!s.enabled) return _centerText('Wi-Fi is turned off');
    if (s.networks.isEmpty) return _centerText('No networks found');

    // Transparent Material so ink effects paint above the popup container.
    return Material(
      type: MaterialType.transparency,
      child: ListView.builder(
        itemCount: s.networks.length,
        itemBuilder: (context, i) => _buildNetwork(s.networks[i]),
      ),
    );
  }

  Widget _centerText(String text) {
    return Center(
      child: Text(
        text,
        style: AppTextStyles.rowSubtitle,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildNetwork(WifiNetwork n) {
    final subtitle = n.isConnecting
        ? 'Connecting...'
        : n.isActive
            ? 'Connected'
            : n.isSaved
                ? 'Saved'
                : n.isSecured
                    ? 'Secured'
                    : 'Open';

    final Widget trailing;
    if (n.isConnecting) {
      trailing = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (n.isActive) {
      trailing = TextButton(
        onPressed: _service.disconnect,
        child: const Text('Disconnect'),
      );
    } else {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (n.isSaved)
            IconButton(
              onPressed: () => _service.forget(n),
              icon: const Icon(Icons.delete_outline),
              iconSize: 16,
              visualDensity: VisualDensity.compact,
              tooltip: 'Forget',
            ),
          if (n.isSecured) const Icon(Icons.lock_outline, size: 14),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _onTap(n),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            child: Row(
              children: [
                Icon(
                  wifiIcon(n.strength),
                  size: 18,
                  color: n.isActive ? _accent : null,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        n.ssid,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.body,
                      ),
                      Text(
                        subtitle,
                        style: n.isActive
                            ? AppTextStyles.rowSubtitle.copyWith(
                                color: _accent,
                              )
                            : AppTextStyles.rowSubtitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                trailing,
              ],
            ),
          ),
        ),
        if (_promptSsid == n.ssid) _buildPasswordRow(n),
      ],
    );
  }

  Widget _buildPasswordRow(WifiNetwork n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _passwordController,
              obscureText: _obscure,
              autofocus: true,
              style: AppTextStyles.body,
              onSubmitted: (_) => _submitPassword(n),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Password',
                filled: true,
                fillColor: AppColors.background,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility : Icons.visibility_off,
                  ),
                  iconSize: 16,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: () => _submitPassword(n),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
