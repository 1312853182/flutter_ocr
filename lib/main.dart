import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'home_page.dart';
import 'ocr_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // 监听来自Android的调用
  const channel = MethodChannel('com.phySicalIDCollection/ocr');
  channel.setMethodCallHandler((call) async {
    if (call.method == 'initModule') {
      OcrChannel.setModuleMode(true);
    }
  });

  runApp(const OcrApp());
}

class OcrApp extends StatelessWidget {
  const OcrApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OCR 文字识别',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}