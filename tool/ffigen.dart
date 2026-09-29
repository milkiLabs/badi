import 'dart:io';

import 'package:ffigen/ffigen.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve("../");
  final generator = FfiGenerator(
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/zig.g.dart'),
      ),
      style: const DynamicLibraryBindings(wrapperName: 'ZigLib'),
    ),
    input: Input(
      entryPoints: [
        packageRoot.resolve("zig_lib/src/zig_lib.h"),
      ],
    ),
    // This includes everything from zig_lib.h.
    visitors: [
      Visitor(
        func: (node) => node.isIncluded = true,
        struct: (node) => node.isIncluded = true,
        union: (node) => node.isIncluded = true,
        enumClass: (node) => node.isIncluded = true,
        global: (node) => node.isIncluded = true,
        macroConstant: (node) => node.isIncluded = true,
        typealias: (node) => node.isIncluded = TypealiasInclude.always,
      ),
    ],
  );
  await generator.generate();
}
