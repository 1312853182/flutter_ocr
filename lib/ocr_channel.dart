import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class OcrChannel {
  static const _channel = MethodChannel('com.phySicalIDCollection/ocr');

  // 标记是否作为模块运行（Android有MethodChannel响应）
  // 默认true，因为从Android启动时就应该使用MethodChannel
  static bool _isModuleMode = true;

  static void setModuleMode(bool value) {
    _isModuleMode = value;
  }

  // OCR完成后返回结果给Android（模块模式）
  static Future<void> sendResult(List<Map<String, dynamic>> plates) async {
    if (_isModuleMode) {
      try {
        await _channel.invokeMethod('onOcrResult', {'plates': plates});
      } catch (e) {
        print('Failed to send result via MethodChannel: $e');
        // Fallback to file
        await _saveResultToFile(plates);
      }
    } else {
      // 独立模式：保存到文件
      await _saveResultToFile(plates);
    }
  }

  // 请求关闭Flutter页面（返回Android）
  static Future<void> closeFlutter() async {
    if (_isModuleMode) {
      try {
        await _channel.invokeMethod('closeFlutter');
      } catch (e) {
        print('Failed to close flutter: $e');
      }
    }
  }

  // 返回错误
  static Future<void> sendError(String message) async {
    if (_isModuleMode) {
      try {
        await _channel.invokeMethod('onOcrError', {'error': message});
      } catch (e) {
        print('Failed to send error via MethodChannel: $e');
      }
    }
  }

  // 保存结果到文件（独立模式）
  static Future<String> _saveResultToFile(List<Map<String, dynamic>> plates) async {
    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/ocr_result.json');

    final data = {
      'plates': plates,
      'timestamp': DateTime.now().toIso8601String(),
    };

    await file.writeAsString(data.toString());
    print('Result saved to: ${file.path}');
    return file.path;
  }

  // 获取结果文件路径
  static Future<String> getResultFilePath() async {
    final directory = await getApplicationDocumentsDirectory();
    return '${directory.path}/ocr_result.json';
  }

  // 清除结果文件
  static Future<void> clearResultFile() async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final file = File('${directory.path}/ocr_result.json');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Failed to clear result file: $e');
    }
  }
}