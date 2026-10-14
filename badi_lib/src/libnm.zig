const std = @import("std");
const c = @import("c");

/// Owned slice helper returned by enumeration helpers.
pub fn freeSlice(comptime T: type, allocator: std.mem.Allocator, slice: []T) void {
    allocator.free(slice);
}

/// Coarse device kinds, useful for filtering UI lists.
pub const DeviceKind = enum {
    unknown,
    ethernet,
    wifi,
    bt,
    olpc_mesh,
    wimax,
    modem,
    infiniband,
    bond,
    vlan,
    adsl,
    bridge,
    generic,
    team,
    tun,
    ip_tunnel,
    macvlan,
    vxlan,
    veth,
    macsec,
    dummy,
    ppp,
    ovs_interface,
    ovs_port,
    ovs_bridge,
    wp_unmatched,
    wireguard,
};

/// A Wi-Fi network visible to an interface.
pub const WifiNetwork = struct {
    /// UTF-8 SSID (owned; free with `allocator.free` or release via `freeWifiNetworks`).
    ssid: []const u8,
    strength: u8,
    frequency_mhz: u32,
    max_bitrate_kbps: u32,
};

/// Release networks returned by `collectWifiNetworks`.
pub fn freeWifiNetworks(allocator: std.mem.Allocator, networks: []WifiNetwork) void {
    for (networks) |net| allocator.free(net.ssid);
    allocator.free(networks);
}

/// Map libnm's numeric device type to a UI-friendly enum.
pub fn deviceKind(device_type: c.NMDeviceType) DeviceKind {
    return switch (device_type) {
        c.NM_DEVICE_TYPE_ETHERNET => .ethernet,
        c.NM_DEVICE_TYPE_WIFI => .wifi,
        c.NM_DEVICE_TYPE_BT => .bt,
        c.NM_DEVICE_TYPE_OLPC_MESH => .olpc_mesh,
        c.NM_DEVICE_TYPE_WIMAX => .wimax,
        c.NM_DEVICE_TYPE_MODEM => .modem,
        c.NM_DEVICE_TYPE_INFINIBAND => .infiniband,
        c.NM_DEVICE_TYPE_BOND => .bond,
        c.NM_DEVICE_TYPE_VLAN => .vlan,
        c.NM_DEVICE_TYPE_ADSL => .adsl,
        c.NM_DEVICE_TYPE_BRIDGE => .bridge,
        c.NM_DEVICE_TYPE_GENERIC => .generic,
        c.NM_DEVICE_TYPE_TEAM => .team,
        c.NM_DEVICE_TYPE_TUN => .tun,
        c.NM_DEVICE_TYPE_IP_TUNNEL => .ip_tunnel,
        c.NM_DEVICE_TYPE_MACVLAN => .macvlan,
        c.NM_DEVICE_TYPE_VXLAN => .vxlan,
        c.NM_DEVICE_TYPE_VETH => .veth,
        c.NM_DEVICE_TYPE_MACSEC => .macsec,
        c.NM_DEVICE_TYPE_DUMMY => .dummy,
        c.NM_DEVICE_TYPE_PPP => .ppp,
        c.NM_DEVICE_TYPE_OVS_INTERFACE => .ovs_interface,
        c.NM_DEVICE_TYPE_OVS_PORT => .ovs_port,
        c.NM_DEVICE_TYPE_OVS_BRIDGE => .ovs_bridge,
        c.NM_DEVICE_TYPE_WPAN => .wp_unmatched,
        c.NM_DEVICE_TYPE_WIREGUARD => .wireguard,
        else => .unknown,
    };
}

/// Create a new NMClient (synchronous). Returns null on failure.
/// Lifetime: call `destroyClient` when done.
pub fn newClient() ?*c.NMClient {
    return c.nm_client_new(null, null);
}

/// Decrease the reference count of an NMClient.
pub fn destroyClient(client: *c.NMClient) void {
    c.g_object_unref(client);
}

/// libnm version string (owned by libnm; do not free).
pub fn clientVersion(client: *c.NMClient) ?[]const u8 {
    const v = c.nm_client_get_version(client) orelse return null;
    return std.mem.span(v);
}

/// Overall NetworkManager state (NM_STATE_*).
pub fn clientState(client: *c.NMClient) c.NMState {
    return c.nm_client_get_state(client);
}

/// Connectivity state (NM_CONNECTIVITY_*).
pub fn connectivity(client: *c.NMClient) c.NMConnectivityState {
    return c.nm_client_get_connectivity(client);
}

/// Whether networking is globally enabled.
pub fn networkingEnabled(client: *c.NMClient) bool {
    return c.nm_client_get_networking_enabled(client) != 0;
}

/// Whether Wi-Fi is globally enabled.
pub fn wirelessEnabled(client: *c.NMClient) bool {
    return c.nm_client_get_wireless_enabled(client) != 0;
}

/// Enable/disable networking globally.
pub fn setNetworkingEnabled(client: *c.NMClient, enabled: bool) void {
    c.nm_client_networking_set_enabled(client, @intFromBool(enabled));
}

/// Enable/disable Wi-Fi globally.
pub fn setWirelessEnabled(client: *c.NMClient, enabled: bool) void {
    c.nm_client_wireless_set_enabled(client, @intFromBool(enabled));
}

/// Interface name for a device (borrowed; valid while device exists).
pub fn deviceIface(device: *c.NMDevice) []const u8 {
    const ptr = c.nm_device_get_iface(device) orelse return "";
    return std.mem.span(ptr);
}

/// Raw device state (NM_DEVICE_STATE_*).
pub fn deviceState(device: *c.NMDevice) c.NMDeviceState {
    return c.nm_device_get_state(device);
}

/// Raw device type (NM_DEVICE_TYPE_*).
pub fn deviceType(device: *c.NMDevice) c.NMDeviceType {
    return c.nm_device_get_device_type(device);
}

/// Human-readable kind for a device.
pub fn deviceKindOf(device: *c.NMDevice) DeviceKind {
    return deviceKind(deviceType(device));
}

/// Trigger a Wi-Fi scan on the given device.
pub fn requestScan(device: *c.NMDeviceWifi) bool {
    return c.nm_device_wifi_request_scan(device, null, null) != 0;
}

/// Collect raw device pointers (borrowed; valid while client exists).
/// Caller owns the returned slice and must `allocator.free` it.
pub fn collectDevices(client: *c.NMClient, allocator: std.mem.Allocator) ![]*c.NMDevice {
    const devices = c.nm_client_get_devices(client) orelse return &.{};
    const arr = devices.*;
    const src = @as([*]const ?*c.NMDevice, @ptrCast(arr.pdata));

    const out = try allocator.alloc(*c.NMDevice, arr.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        if (src[i]) |dev| {
            out[n] = dev;
            n += 1;
        }
    }
    // Shrink to actual count.
    const used = try allocator.realloc(out, n);
    return used;
}

/// Collect Wi-Fi networks for a device.
/// Each `ssid` in the result is owned; release with `freeWifiNetworks`.
pub fn collectWifiNetworks(
    device: *c.NMDeviceWifi,
    allocator: std.mem.Allocator,
) ![]WifiNetwork {
    const aps = c.nm_device_wifi_get_access_points(device) orelse return &.{};
    const arr = aps.*;
    const src = @as([*]const ?*c.NMAccessPoint, @ptrCast(arr.pdata));

    var list: std.ArrayList(WifiNetwork) = .empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < arr.len) : (i += 1) {
        const ap = src[i] orelse continue;

        var size: c.gsize = 0;
        var ssid_slice: []const u8 = "<hidden>";
        if (c.nm_access_point_get_ssid(ap)) |bytes| {
            const raw = c.g_bytes_get_data(bytes, &size);
            if (raw != null and size > 0) {
                const converted = c.nm_utils_ssid_to_utf8(
                    @as([*]const u8, @ptrCast(raw)),
                    size,
                );
                if (converted) |conv| {
                    ssid_slice = try allocator.dupe(u8, std.mem.span(conv));
                    c.g_free(conv);
                }
            }
        }

        try list.append(allocator, .{
            .ssid = ssid_slice,
            .strength = c.nm_access_point_get_strength(ap),
            .frequency_mhz = c.nm_access_point_get_frequency(ap),
            .max_bitrate_kbps = c.nm_access_point_get_max_bitrate(ap),
        });
    }

    return try list.toOwnedSlice(allocator);
}

/// Convenience: connect callbacks using GLib's standard signal API.
/// This is a thin wrapper to keep Zig code type-safe at call sites.
pub const Signals = struct {
    // Raw signal names (use with g_signal_connect_data).
    pub const device_added = "device-added";
    pub const device_removed = "device-removed";
    pub const active_connection_added = "active-connection-added";
    pub const active_connection_removed = "active-connection-removed";
    pub const connection_added = "connection-added";
    pub const connection_removed = "connection-removed";
    pub const connection_updated = "connection-updated";
    pub const notify_state = "notify::state";
    pub const notify_connectivity = "notify::connectivity";
    pub const notify_devices = "notify::devices";
    pub const notify_wireless_enabled = "notify::wireless-enabled";
    pub const notify_networking_enabled = "notify::networking-enabled";
};

/// Run the GLib main loop until quit. Returns when `g_main_loop_quit` is called.
pub fn runMainLoop(loop: *c.GMainLoop) void {
    c.g_main_loop_run(loop);
}

/// Create a main loop for an application/service.
pub fn newMainLoop(is_running: bool) ?*c.GMainLoop {
    return c.g_main_loop_new(null, @intFromBool(is_running));
}

/// Request main loop termination (typically from a signal callback).
pub fn quitMainLoop(loop: *c.GMainLoop) void {
    c.g_main_loop_quit(loop);
}

/// Human-readable connectivity state.
pub fn connectivityString(state: c.NMConnectivityState) []const u8 {
    return switch (state) {
        c.NM_CONNECTIVITY_UNKNOWN => "unknown",
        c.NM_CONNECTIVITY_NONE => "none",
        c.NM_CONNECTIVITY_PORTAL => "portal",
        c.NM_CONNECTIVITY_LIMITED => "limited",
        c.NM_CONNECTIVITY_FULL => "full",
        else => "invalid",
    };
}

/// Human-readable device state.
pub fn deviceStateString(state: c.NMDeviceState) []const u8 {
    return switch (state) {
        c.NM_DEVICE_STATE_UNKNOWN => "unknown",
        c.NM_DEVICE_STATE_UNMANAGED => "unmanaged",
        c.NM_DEVICE_STATE_UNAVAILABLE => "unavailable",
        c.NM_DEVICE_STATE_DISCONNECTED => "disconnected",
        c.NM_DEVICE_STATE_PREPARE => "prepare",
        c.NM_DEVICE_STATE_CONFIG => "config",
        c.NM_DEVICE_STATE_NEED_AUTH => "need-auth",
        c.NM_DEVICE_STATE_IP_CONFIG => "ip-config",
        c.NM_DEVICE_STATE_IP_CHECK => "ip-check",
        c.NM_DEVICE_STATE_SECONDARIES => "secondaries",
        c.NM_DEVICE_STATE_ACTIVATED => "activated",
        c.NM_DEVICE_STATE_DEACTIVATING => "deactivating",
        c.NM_DEVICE_STATE_FAILED => "failed",
        else => "unrecognized",
    };
}
