# Badi

A layer-shell launcher and minimal desktop shell for Wayland. Flutter UI over a Zig core (`dart:ffi`).

One binary, three roles:

```sh
badi --shell   # autostart: top bar always on, launcher hidden, serves IPC
badi           # keybinding: opens the launcher via the running daemon
find / | badi  # dmenu mode: pick a piped line, printed to stdout
```

Run a command on each piped item to create its launcher preview. The command
receives the item on stdin; selecting it still prints the original line:

```sh
cat /etc/passwd | badi --launcher --pre-display-cmd='cut -d: -f1'
```

If the command exits unsuccessfully, the original line is used as the preview.

No daemon listening? Bare `badi` falls back to a one-shot window, so piping works without the shell. `Esc` closes the launcher; there is intentionally no toggle command.

## Requirements

Wayland compositor with `zwlr_layer_shell_v1` (Sway, Hyprland, KDE-Wayland, …). Not GNOME-Wayland or X11.

```sh
sudo pacman -S --needed flutter-bin zig cmake ninja pkgconf gtk3 gtk-layer-shell
```

Flutter channel `main` with windowing enabled (`flutter config --enable-windowing`).

## Build & run

Zig first — the Flutter bundle picks up `badi_lib/zig-out/lib/libbadi.so` at install time and only warns when it is missing:

```sh
./tool/build_zig.sh --host
flutter run                        # dev (one-shot; daemon needs a compositor)
flutter build linux --release      # bundle lands in build/linux/x64/release/bundle/
```

Details, ABI checks, and packaging: see [BUILDING.md](BUILDING.md).

## Shell setup

Autostart (either):

```sh
systemctl --user enable --now badi   # ships packaging/badi.service
# or compositor-side: exec-once = badi --shell
```

Keybinding (examples):

```ini
# Hyprland
bind = SUPER, SPACE, exec, badi
```

```ini
# Sway
bindsym $mod+space exec badi
```

IPC is newline-delimited JSON over `$XDG_RUNTIME_DIR/badi.sock` (`lib/platform/ipc.dart`). A lines-mode client blocks until the pick (exit 0) or abort (exit 1, rofi-style); an apps-mode client exits on `ack` while the daemon spawns. A second open while the launcher is visible is rejected — close with `Esc` first.

## Layout

```
lib/main.dart            # --shell / client / one-shot dispatch
lib/ui/                  # bar_page, launcher_page, shell (layer-shell surfaces)
lib/shell/               # shell_controller (state), shell_actions (spawn/reply)
lib/core/                # launcher_controller, session, actions (UI-agnostic)
lib/platform/            # ipc, process_actions, zig lib loading
badi_lib/src/            # Zig core: app scan, filtering, FFI (no UI knowledge)
test/                    # flutter test
```

The Zig core only filters rows and serves row data; all windows, stdio, and process lifetime live in Dart. `lib/core/zig.g.dart` is generated from `badi_lib/src/badi.h` via `dart run tool/ffigen.dart`.
