import 'package:flutter/material.dart';

import 'zig.dart';

void main() {
  runApp(const MainApp());
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

class _MainAppState extends State<MainApp> {
  String _result = 'calling Zig...';

  @override
  void initState() {
    super.initState();
    _callZig();
  }

  void _callZig() {
    try {
      final sum = zigLib.add(40, 2);
      setState(() => _result = 'Zig add(40, 2) = $sum');
    } catch (e) {
      setState(() => _result = 'Failed to load Zig lib: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_result),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _callZig,
                child: const Text('Call Zig again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
