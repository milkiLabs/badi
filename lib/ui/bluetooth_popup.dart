import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'popup_window.dart';

/// Configuration for the Bluetooth popup.
const PopupWindowConfig bluetoothPopupConfig = PopupWindowConfig(
  width: 320,
  height: 440,
  namespace: 'badi-bluetooth-popup',
);

// ---------------------------------------------------------------------------
// BlueZ D-Bus names
// ---------------------------------------------------------------------------

const _bluezName = 'org.bluez';
const _bluezRoot = '/org/bluez';
const _objectManagerIface = 'org.freedesktop.DBus.ObjectManager';
const _propertiesIface = 'org.freedesktop.DBus.Properties';
const _adapterIface = 'org.bluez.Adapter1';
const _deviceIface = 'org.bluez.Device1';
const _batteryIface = 'org.bluez.Battery1';
const _agentManagerIface = 'org.bluez.AgentManager1';
const _agentIface = 'org.bluez.Agent1';

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

class BluetoothDevice {
  const BluetoothDevice({
    required this.path,
    required this.name,
    required this.address,
    required this.icon,
    required this.paired,
    required this.connected,
    this.rssi,
    this.battery,
  });

  final DBusObjectPath path;
  final String name;
  final String address;

  /// Freedesktop icon name reported by BlueZ, for example audio-headphones.
  final String? icon;
  final bool paired;
  final bool connected;

  /// Signal strength in dBm, only known while the device is nearby.
  final int? rssi;

  /// Battery percentage, if the device reports one.
  final int? battery;
}

/// Maps a BlueZ icon name to a Material icon.
IconData bluetoothDeviceIcon(String? icon) {
  switch (icon) {
    case 'audio-headphones':
    case 'audio-headset':
      return Icons.headphones;
    case 'audio-card':
    case 'audio-speakers':
      return Icons.speaker;
    case 'input-keyboard':
      return Icons.keyboard;
    case 'input-mouse':
      return Icons.mouse;
    case 'input-gaming':
      return Icons.sports_esports;
    case 'input-tablet':
      return Icons.tablet;
    case 'phone':
      return Icons.smartphone;
    case 'computer':
      return Icons.computer;
    case 'printer':
      return Icons.print;
    case 'camera-photo':
    case 'camera-video':
      return Icons.photo_camera;
    default:
      return Icons.bluetooth;
  }
}

// ---------------------------------------------------------------------------
// Pairing agent
// ---------------------------------------------------------------------------

/// A minimal BlueZ agent with NoInputNoOutput capability. It is registered
/// only while this app is pairing a device itself, and it rejects every
/// request that arrives outside that window, so nearby devices cannot pair
/// with this machine through it.
///
/// Devices that need a PIN or passkey typed in by the user are not supported;
/// use a full Bluetooth manager for those.
class _PairingAgent extends DBusObject {
  _PairingAgent() : super(DBusObjectPath('/org/badi/bluetooth_agent'));

  bool active = false;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface != _agentIface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (methodCall.name) {
      case 'Release':
      case 'Cancel':
      case 'DisplayPinCode':
      case 'DisplayPasskey':
        return DBusMethodSuccessResponse();
      case 'RequestConfirmation':
      case 'RequestAuthorization':
      case 'AuthorizeService':
        return active
            ? DBusMethodSuccessResponse()
            : DBusMethodErrorResponse('org.bluez.Error.Rejected');
      case 'RequestPinCode':
        return active
            ? DBusMethodSuccessResponse([DBusString('0000')])
            : DBusMethodErrorResponse('org.bluez.Error.Rejected');
      case 'RequestPasskey':
        return active
            ? DBusMethodSuccessResponse([DBusUint32(0)])
            : DBusMethodErrorResponse('org.bluez.Error.Rejected');
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
  }
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Talks to BlueZ over the system D-Bus. Shared by the popup and by
/// [BluetoothStatusIcon]. Polling and signal subscriptions only run while at
/// least one widget has called [start] without a matching [stop].
class BluetoothService extends ChangeNotifier {
  BluetoothService._();

  static final BluetoothService instance = BluetoothService._();

  // Public state.
  bool available = false;
  String? statusMessage = 'Connecting to BlueZ...';
  bool powered = false;
  bool discovering = false;
  List<BluetoothDevice> devices = const [];
  DBusObjectPath? busyPath;
  String? error;

  int get connectedCount => devices.where((d) => d.connected).length;

  DBusClient? _client;
  DBusRemoteObject? _adapter;
  DBusObjectPath? _adapterPath;
  final _agent = _PairingAgent();
  bool _agentRegistered = false;

  final List<StreamSubscription<dynamic>> _subs = [];
  bool _subscribed = false;
  int _users = 0;
  Timer? _poll;
  Timer? _debounce;
  Timer? _errorTimer;
  bool _refreshing = false;
  bool _refreshAgain = false;

  /// True while a popup wants discovery running.
  bool _autoScan = false;
  bool _startingScan = false;

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
    _debounce = Timer(const Duration(milliseconds: 300), refresh);
  }

  void _setUnavailable(String message) {
    available = false;
    statusMessage = message;
    powered = false;
    discovering = false;
    devices = const [];
    notifyListeners();
  }

  Future<void> _load() async {
    try {
      final client = _client ??= DBusClient.system();
      final root = DBusRemoteObject(
        client,
        name: _bluezName,
        path: DBusObjectPath('/'),
      );
      final reply = await root.callMethod(
        _objectManagerIface,
        'GetManagedObjects',
        [],
        replySignature: DBusSignature('a{oa{sa{sv}}}'),
      );

      final adapters = <DBusObjectPath, Map<String, DBusValue>>{};
      final deviceProps = <DBusObjectPath, Map<String, DBusValue>>{};
      final battery = <DBusObjectPath, int>{};

      for (final entry in reply.returnValues[0].asDict().entries) {
        final path = entry.key.asObjectPath();
        for (final iface in entry.value.asDict().entries) {
          final props = iface.value.asStringVariantDict();
          switch (iface.key.asString()) {
            case _adapterIface:
              adapters[path] = props;
            case _deviceIface:
              deviceProps[path] = props;
            case _batteryIface:
              final pct = props['Percentage'];
              if (pct != null) battery[path] = pct.asByte();
          }
        }
      }

      if (adapters.isEmpty) {
        _adapter = null;
        _adapterPath = null;
        _setUnavailable('No Bluetooth adapter found');
        return;
      }

      // Use the first adapter, normally hci0.
      final adapterPath = adapters.keys
          .reduce((a, b) => a.value.compareTo(b.value) <= 0 ? a : b);
      final adapterProps = adapters[adapterPath]!;
      if (_adapterPath != adapterPath) {
        _adapterPath = adapterPath;
        _adapter = DBusRemoteObject(
          client,
          name: _bluezName,
          path: adapterPath,
        );
      }

      available = true;
      statusMessage = null;
      powered = adapterProps['Powered']?.asBoolean() ?? false;
      discovering = adapterProps['Discovering']?.asBoolean() ?? false;

      final prefix = '${adapterPath.value}/';
      final list = <BluetoothDevice>[];
      deviceProps.forEach((path, props) {
        if (!path.value.startsWith(prefix)) return;
        final paired = props['Paired']?.asBoolean() ?? false;
        // Unpaired devices that never advertised a name are just noise.
        if (!paired && !props.containsKey('Name')) return;
        final address = props['Address']?.asString() ?? '';
        list.add(
          BluetoothDevice(
            path: path,
            name: props['Alias']?.asString() ?? address,
            address: address,
            icon: props['Icon']?.asString(),
            paired: paired,
            connected: props['Connected']?.asBoolean() ?? false,
            rssi: props['RSSI']?.asInt16(),
            battery: battery[path],
          ),
        );
      });

      list.sort((a, b) {
        if (a.paired != b.paired) return a.paired ? -1 : 1;
        if (a.paired) {
          if (a.connected != b.connected) return a.connected ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        return (b.rssi ?? -200).compareTo(a.rssi ?? -200);
      });
      devices = list;
      notifyListeners();
      _subscribe();

      if (_autoScan &&
          powered &&
          !discovering &&
          busyPath == null &&
          !_startingScan) {
        _startingScan = true;
        try {
          await _adapter!.callMethod(
            _adapterIface,
            'StartDiscovery',
            [],
            replySignature: DBusSignature(''),
          );
        } catch (_) {
          // Another client may already be scanning.
        } finally {
          _startingScan = false;
        }
        _scheduleRefresh();
      }
    } catch (_) {
      _adapter = null;
      _adapterPath = null;
      _unsubscribe();
      _setUnavailable('Bluetooth service is not available');
    }
  }

  // -- Signals ---------------------------------------------------------------

  void _subscribe() {
    final client = _client;
    if (_subscribed || _users == 0 || client == null) return;
    _subscribed = true;
    // InterfacesAdded and InterfacesRemoved when devices appear or vanish.
    _subs.add(
      DBusSignalStream(
        client,
        sender: _bluezName,
        interface: _objectManagerIface,
      ).listen((_) => _scheduleRefresh()),
    );
    // Property changes on the adapter and on every device.
    _subs.add(
      DBusSignalStream(
        client,
        sender: _bluezName,
        interface: _propertiesIface,
        name: 'PropertiesChanged',
        pathNamespace: DBusObjectPath(_bluezRoot),
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

  // -- Discovery -------------------------------------------------------------

  /// Called by the popup when it opens.
  void beginScan() {
    _autoScan = true;
    _scheduleRefresh();
  }

  /// Called by the popup when it closes.
  Future<void> endScan() async {
    _autoScan = false;
    await _stopDiscovery();
  }

  /// Manual toggle from the scan button.
  Future<void> toggleScan() async {
    if (discovering) {
      _autoScan = false;
      await _stopDiscovery();
    } else {
      _autoScan = true;
    }
    await refresh();
  }

  Future<void> _stopDiscovery() async {
    final adapter = _adapter;
    if (adapter == null || !discovering) return;
    try {
      await adapter.callMethod(
        _adapterIface,
        'StopDiscovery',
        [],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      // Not scanning, or scanning on behalf of another client.
    }
  }

  // -- Actions ---------------------------------------------------------------

  Future<void> setPowered(bool value) async {
    powered = value;
    notifyListeners();
    try {
      await _adapter?.setProperty(_adapterIface, 'Powered', DBusBoolean(value));
    } catch (_) {
      reportError('Could not change Bluetooth state. Is it blocked by rfkill?');
    }
    await refresh();
  }

  DBusRemoteObject _deviceObject(DBusObjectPath path) =>
      DBusRemoteObject(_client!, name: _bluezName, path: path);

  /// Connects to [device], pairing and trusting it first if needed.
  Future<void> connect(BluetoothDevice device) async {
    if (busyPath != null || _client == null) return;
    _clearError();
    busyPath = device.path;
    notifyListeners();

    try {
      // BlueZ connects and pairs more reliably with discovery stopped.
      await _stopDiscovery();
      final obj = _deviceObject(device.path);

      if (!device.paired) {
        await _registerAgent();
        try {
          await obj.callMethod(
            _deviceIface,
            'Pair',
            [],
            replySignature: DBusSignature(''),
          );
        } finally {
          await _unregisterAgent();
        }
        await obj.setProperty(_deviceIface, 'Trusted', DBusBoolean(true));
      }

      await obj.callMethod(
        _deviceIface,
        'Connect',
        [],
        replySignature: DBusSignature(''),
      );
    } catch (e) {
      reportError(_describe(e));
    } finally {
      busyPath = null;
      await refresh();
    }
  }

  Future<void> disconnect(BluetoothDevice device) async {
    if (busyPath != null || _client == null) return;
    _clearError();
    busyPath = device.path;
    notifyListeners();
    try {
      await _deviceObject(device.path).callMethod(
        _deviceIface,
        'Disconnect',
        [],
        replySignature: DBusSignature(''),
      );
    } catch (e) {
      reportError(_describe(e));
    } finally {
      busyPath = null;
      await refresh();
    }
  }

  /// Unpairs and removes [device].
  Future<void> forget(BluetoothDevice device) async {
    final adapter = _adapter;
    if (adapter == null) return;
    _clearError();
    try {
      await adapter.callMethod(
        _adapterIface,
        'RemoveDevice',
        [device.path],
        replySignature: DBusSignature(''),
      );
    } catch (e) {
      reportError(_describe(e));
    }
    await refresh();
  }

  Future<void> _registerAgent() async {
    final client = _client!;
    if (!_agentRegistered) {
      await client.registerObject(_agent);
      _agentRegistered = true;
    }
    _agent.active = true;
    try {
      await DBusRemoteObject(
        client,
        name: _bluezName,
        path: DBusObjectPath(_bluezRoot),
      ).callMethod(
        _agentManagerIface,
        'RegisterAgent',
        [_agent.path, DBusString('NoInputNoOutput')],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      // Already registered from an earlier attempt.
    }
  }

  Future<void> _unregisterAgent() async {
    _agent.active = false;
    try {
      await DBusRemoteObject(
        _client!,
        name: _bluezName,
        path: DBusObjectPath(_bluezRoot),
      ).callMethod(
        _agentManagerIface,
        'UnregisterAgent',
        [_agent.path],
        replySignature: DBusSignature(''),
      );
    } catch (_) {
      // Nothing to clean up.
    }
  }

  /// Opens a full Bluetooth manager for anything the popup cannot do, such as
  /// pairing devices that need a PIN typed in.
  Future<void> openSettings() async {
    for (final command in const ['blueman-manager', 'blueberry']) {
      try {
        await Process.start(command, const [], mode: ProcessStartMode.detached);
        return;
      } catch (_) {
        // Try the next one.
      }
    }
    reportError('No Bluetooth manager found (try blueman)');
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('AuthenticationFailed')) return 'Pairing failed';
    if (text.contains('AuthenticationTimeout')) return 'Pairing timed out';
    if (text.contains('AuthenticationRejected')) return 'Pairing was rejected';
    if (text.contains('ConnectionAttemptFailed')) return 'Connection failed';
    if (text.contains('NotReady')) return 'Bluetooth is not ready';
    if (text.contains('Failed')) return 'The operation failed';
    return text.length > 80 ? '${text.substring(0, 80)}...' : text;
  }
}

// ---------------------------------------------------------------------------
// Bar icon
// ---------------------------------------------------------------------------

/// Small status icon for the bar. Reflects power and connection state.
class BluetoothStatusIcon extends StatefulWidget {
  const BluetoothStatusIcon({super.key, this.size = 18});

  final double size;

  @override
  State<BluetoothStatusIcon> createState() => _BluetoothStatusIconState();
}

class _BluetoothStatusIconState extends State<BluetoothStatusIcon> {
  final _service = BluetoothService.instance;

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
    if (!s.available || !s.powered) {
      icon = Icons.bluetooth_disabled;
    } else if (s.connectedCount > 0) {
      icon = Icons.bluetooth_connected;
    } else {
      icon = Icons.bluetooth;
    }
    return Icon(icon, size: widget.size);
  }
}

// ---------------------------------------------------------------------------
// Popup content
// ---------------------------------------------------------------------------

const _accent = Colors.lightBlueAccent;

/// Bluetooth popup content: power toggle, scan, paired and nearby devices,
/// connect, disconnect, forget and a shortcut to a full manager.
class BluetoothPopupContent extends StatefulWidget {
  const BluetoothPopupContent({super.key});

  @override
  State<BluetoothPopupContent> createState() => _BluetoothPopupContentState();
}

class _BluetoothPopupContentState extends State<BluetoothPopupContent> {
  final _service = BluetoothService.instance;

  @override
  void initState() {
    super.initState();
    _service.addListener(_onChange);
    _service.start();
    _service.beginScan();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _service.removeListener(_onChange);
    _service.endScan();
    _service.stop();
    super.dispose();
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

  Widget _buildHeader(BluetoothService s) {
    return Row(
      children: [
        Text('Bluetooth', style: AppTextStyles.rowTitle),
        const Spacer(),
        if (s.available && s.powered)
          s.discovering
              ? IconButton(
                  onPressed: s.toggleScan,
                  icon: const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Stop scanning',
                )
              : IconButton(
                  onPressed: s.toggleScan,
                  icon: const Icon(Icons.refresh),
                  iconSize: 18,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Scan',
                ),
        if (s.available) Switch(value: s.powered, onChanged: s.setPowered),
      ],
    );
  }

  Widget _buildBody(BluetoothService s) {
    if (!s.available) {
      return _centerText(s.statusMessage ?? 'Bluetooth is unavailable');
    }
    if (!s.powered) return _centerText('Bluetooth is turned off');
    if (s.devices.isEmpty) {
      return _centerText(
        s.discovering ? 'Searching for devices...' : 'No devices found',
      );
    }

    final paired = s.devices.where((d) => d.paired).toList();
    final nearby = s.devices.where((d) => !d.paired).toList();

    // Transparent Material so ink effects paint above the popup container.
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        children: [
          if (paired.isNotEmpty) _section('My devices'),
          ...paired.map(_buildDevice),
          if (nearby.isNotEmpty) _section('Available'),
          ...nearby.map(_buildDevice),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 4),
      child: Text(title, style: AppTextStyles.rowSubtitle),
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

  Widget _buildDevice(BluetoothDevice d) {
    final busy = _service.busyPath == d.path;

    final String subtitle;
    if (busy) {
      subtitle = d.paired ? 'Working...' : 'Pairing...';
    } else if (d.connected) {
      subtitle = d.battery != null ? 'Connected, ${d.battery}%' : 'Connected';
    } else if (d.paired) {
      subtitle = 'Paired';
    } else {
      subtitle = 'Not paired';
    }

    final Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (d.connected) {
      trailing = TextButton(
        onPressed: () => _service.disconnect(d),
        child: const Text('Disconnect'),
      );
    } else if (d.paired) {
      trailing = IconButton(
        onPressed: () => _service.forget(d),
        icon: const Icon(Icons.delete_outline),
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        tooltip: 'Forget',
      );
    } else {
      trailing = const SizedBox.shrink();
    }

    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: (busy || d.connected || _service.busyPath != null)
          ? null
          : () => _service.connect(d),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          children: [
            Icon(
              bluetoothDeviceIcon(d.icon),
              size: 18,
              color: d.connected ? _accent : null,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.body,
                  ),
                  Text(
                    subtitle,
                    style: d.connected
                        ? AppTextStyles.rowSubtitle.copyWith(color: _accent)
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
    );
  }
}
