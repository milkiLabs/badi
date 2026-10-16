/// Window-manager-agnostic workspace model for the bar indicator.
///
/// Each backend (Sway today, Hyprland/i3 tomorrow) maps its native
/// workspace JSON into [WmWorkspace]. The bar only depends on this type,
/// never on backend specifics.
class WmWorkspace {
  const WmWorkspace({
    required this.id,
    required this.name,
    this.num,
    this.focused = false,
    this.visible = false,
    this.urgent = false,
    this.hasWindows = false,
    this.output,
  });

  /// Stable identifier for keys / focus requests. Backends use whatever is
  /// most stable (Sway: numeric [num] when present, else [name]).
  final String id;

  /// Raw compositor name (e.g. Sway `"1: web"`).
  final String name;

  /// Numeric index when the compositor provides one.
  final int? num;

  final bool focused;
  final bool visible;
  final bool urgent;
  final bool hasWindows;
  final String? output;

  /// Short label for the bar chip. Prefers the number (`"1"`) so
  /// `"1: web"` and `"1: "` both render as `1`.
  String get displayLabel => num?.toString() ?? name;

  /// Parses one entry of Sway/i3 `GET_WORKSPACES`.
  ///
  /// Window presence ORs every signal Sway/i3 versions provide: Sway 1.11+
  /// leaves `nodes`/`floating_nodes` empty in `GET_WORKSPACES` (windows only
  /// appear in `GET_TREE`), so `representation` (`"H[kitty]"` vs `null`) and
  /// the `focus` stack are the reliable occupancy signals there. Older
  /// payloads populate the node lists, which still count.
  factory WmWorkspace.fromSwayJson(Map<String, dynamic> json) {
    final rawNum = json['num'];
    final int? number;
    if (rawNum is int) {
      number = rawNum;
    } else if (rawNum is double) {
      number = rawNum.toInt();
    } else {
      number = null;
    }
    final name = (json['name'] ?? number?.toString() ?? '') as String;
    final nodes = json['nodes'] as List?;
    final floating = json['floating_nodes'] as List?;
    final repr = json['representation'];
    final focus = json['focus'] as List?;
    final hasWindows = (nodes?.isNotEmpty ?? false) ||
        (floating?.isNotEmpty ?? false) ||
        (repr is String && repr.isNotEmpty) ||
        (focus?.isNotEmpty ?? false);
    return WmWorkspace(
      id: number?.toString() ?? name,
      name: name,
      num: number,
      focused: json['focused'] == true,
      visible: json['visible'] == true,
      urgent: json['urgent'] == true,
      hasWindows: hasWindows,
      output: json['output'] as String?,
    );
  }

  /// Parses the full `GET_WORKSPACES` payload, skipping scratchpad-style
  /// internals (`__i3_scratch`). Sorted by number, then name, so the bar
  /// order is stable regardless of compositor order.
  static List<WmWorkspace> listFromSwayJson(Object? json) {
    if (json is! List) return const [];
    final out = <WmWorkspace>[];
    for (final entry in json) {
      if (entry is! Map) continue;
      final m = Map<String, dynamic>.from(entry);
      final name = (m['name'] ?? '') as String;
      if (name == '__i3_scratch') continue;
      out.add(WmWorkspace.fromSwayJson(m));
    }
    out.sort((a, b) {
      final an = a.num ?? 1 << 30;
      final bn = b.num ?? 1 << 30;
      if (an != bn) return an.compareTo(bn);
      return a.name.compareTo(b.name);
    });
    return out;
  }

  @override
  bool operator ==(Object other) =>
      other is WmWorkspace &&
      other.id == id &&
      other.name == name &&
      other.num == num &&
      other.focused == focused &&
      other.visible == visible &&
      other.urgent == urgent &&
      other.hasWindows == hasWindows &&
      other.output == output;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        num,
        focused,
        visible,
        urgent,
        hasWindows,
        output,
      );

  @override
  String toString() =>
      'WmWorkspace($displayLabel focused=$focused visible=$visible urgent=$urgent hasWindows=$hasWindows)';
}
