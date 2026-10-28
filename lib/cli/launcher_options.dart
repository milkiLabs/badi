/// Parses options specific to `badi --launcher`.
class LauncherOptions {
  const LauncherOptions._();

  static String? parse(List<String> args) {
    String? command;

    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--pre-display-cmd') {
        if (i + 1 >= args.length) {
          throw FormatException('$arg requires a value');
        }
        command = args[++i];
      } else if (arg.startsWith('--pre-display-cmd=')) {
        command = arg.substring('--pre-display-cmd='.length);
      } else if (arg != '--launcher') {
        throw FormatException('unknown option: $arg');
      }
    }

    if (command != null && command.isEmpty) {
      throw FormatException('--pre-display-cmd must be non-empty');
    }
    return command;
  }
}
