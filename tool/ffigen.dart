import 'dart:io';

import 'package:ffigen/ffigen.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve("../");
  final generator = FfiGenerator(
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/core/zig.g.dart'),
      ),
      style: const DynamicLibraryBindings(wrapperName: 'BadiLib'),
    ),
    input: Input(
      entryPoints: [
        packageRoot.resolve("badi_lib/src/badi.h"),
      ],
    ),
    // This includes everything from badi.h.
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
