import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

import '../models/press_plate.dart';

/// 区间类，用于合并重叠的纵向区间
class _Interval {
  double start;
  double end;
  _Interval({required this.start, required this.end});

  bool overlaps(_Interval other) {
    return start <= other.end && end >= other.start;
  }

  _Interval merge(_Interval other) {
    return _Interval(
      start: math.min(start, other.start),
      end: math.max(end, other.end),
    );
  }
}

/// 文本块类，存储块的边界和包含的元素
class Block {
  double left;
  double right;
  double top;
  double bottom;
  List<TextElement> elements;
  int row;
  int col;

  Block({
    required this.left,
    required this.right,
    required this.top,
    required this.bottom,
    required this.elements,
    required this.row,
    required this.col,
  });
}

class OcrService {
  final TextRecognizer _textRecognizer = TextRecognizer(
    script: TextRecognitionScript.chinese,
  );

  void dispose() {
    _textRecognizer.close();
  }

  /// 基于密度曲线的分割线检测
  List<Block> buildGridFromClusters(
    RecognizedText result,
    Size originalImageSize,
  ) {

    // 收集所有匹配的压板元素
    final elements = <TextElement>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final text = element.text.trim();
          elements.add(TextElement(
            text: text,
            boundingBox: element.boundingBox,
            confidence: element.confidence,
          ));
        }
      }
    }
    if (elements.isEmpty) return [];

    // 遍历elements，用区间合并的方式获取行区间
    final yIntervals = <_Interval>[];
    for (final el in elements) {
      var interval = _Interval(
        start: el.boundingBox.top.toDouble(),
        end: el.boundingBox.bottom.toDouble(),
      );

      // 检查是否与已有区间重叠，合并所有重叠的区间
      var i = 0;
      while (i < yIntervals.length) {
        if (yIntervals[i].overlaps(interval)) {
          interval = yIntervals[i].merge(interval);
          yIntervals.removeAt(i);
        } else {
          i++;
        }
      }
      yIntervals.add(interval);
    }
    yIntervals.sort((a, b) => a.start.compareTo(b.start));

    print('[GridDebug] Y方向行区间: ${yIntervals.map((iv) => '[${iv.start.toStringAsFixed(0)}, ${iv.end.toStringAsFixed(0)}]').toList()}');

    // 从区间计算行边界和行中心
    final yBoundariesList = <double>[];
    final rowCenters = <double>[];

    for (int i = 0; i < yIntervals.length; i++) {
      if (i < yIntervals.length - 1) {
        // 边界线取两个相邻区间的中点
        final gap = yIntervals[i + 1].start - yIntervals[i].end;
        yBoundariesList.add(yIntervals[i].end + gap / 2);
      }
      // 行中心取区间中点
      rowCenters.add((yIntervals[i].start + yIntervals[i].end) / 2);
    }

    print('[GridDebug] Y方向行边界: $yBoundariesList');
    print('[GridDebug] Y方向行中心: $rowCenters');

    // 找出图片高度区间中，所有没有块映射的空白区间
    final imageHeight = originalImageSize.height;
    final emptyIntervals = <_Interval>[];
    var currentStart = 0.0;

    for (final iv in yIntervals) {
      if (iv.start > currentStart) {
        emptyIntervals.add(_Interval(
          start: currentStart,
          end: iv.start,
        ));
      }
      currentStart = iv.end;
    }
    if (currentStart < imageHeight) {
      emptyIntervals.add(_Interval(
        start: currentStart,
        end: imageHeight,
      ));
    }

    print('[GridDebug] Y方向空白区间(无块映射): ${emptyIntervals.map((iv) => '[${iv.start.toStringAsFixed(0)}, ${iv.end.toStringAsFixed(0)}]').toList()}');


    // ========== X方向：按行区间分组elements ==========
    // 用Y方向区间直接将elements分配到各行
    final elementsByRow = <int, List<TextElement>>{};
    for (final el in elements) {
      final elInterval = _Interval(
        start: el.boundingBox.top.toDouble(),
        end: el.boundingBox.bottom.toDouble(),
      );
      for (int i = 0; i < yIntervals.length; i++) {
        if (elInterval.overlaps(yIntervals[i])) {
          elementsByRow.putIfAbsent(i, () => []).add(el);
          break;
        }
      }
    }

    print('[GridDebug] 元素按行区间分配到行:');
    for (final entry in elementsByRow.entries) {
      print('[GridDebug]   行${entry.key}: ${entry.value.length}个元素');
    }

    // ========== X方向：对每一行按区间划分blocks ==========
    final blocksAllRows = <int, List<Block>>{};

    for (final rowEntry in elementsByRow.entries) {
      final rowIdx = rowEntry.key;
      final rowElements = rowEntry.value;

      final rowTop = rowIdx == 0 ? 0.0 : yBoundariesList[rowIdx - 1];
      final rowBottom = rowIdx == yBoundariesList.length ? imageHeight : yBoundariesList[rowIdx];

      // 收集元素X方向的区间（用于合并）
      final xIntervals = <_Interval>[];
      for (final el in rowElements) {
        xIntervals.add(_Interval(
          start: el.boundingBox.left.toDouble(),
          end: el.boundingBox.right.toDouble(),
        ));
      }
      xIntervals.sort((a, b) => a.start.compareTo(b.start));

      // 合并重叠的X区间得到有映射的区间
      final mergedXIntervals = <_Interval>[];
      for (final iv in xIntervals) {
        if (mergedXIntervals.isEmpty || !mergedXIntervals.last.overlaps(iv)) {
          mergedXIntervals.add(_Interval(start: iv.start, end: iv.end));
        } else {
          mergedXIntervals[mergedXIntervals.length - 1] = mergedXIntervals.last.merge(iv);
        }
      }

      // 找出X方向所有空白区间
      final emptyXIntervals = <_Interval>[];
      var currentX = 0.0;
      var rowRight = originalImageSize.width;
      for (final iv in mergedXIntervals) {
        if (iv.start > currentX) {
          emptyXIntervals.add(_Interval(start: currentX, end: iv.start));
        }
        currentX = iv.end;
      }
      if (currentX < rowRight) {
        emptyXIntervals.add(_Interval(start: currentX, end: rowRight));
      }

      // 统计方法过滤空白区间
      final blocks = <Block>[];
      for (int colIdx = 0; colIdx < mergedXIntervals.length; colIdx++) {
        final iv = mergedXIntervals[colIdx];
        final elemsInBlock = rowElements.where((el) {
          final elLeft = el.boundingBox.left.toDouble();
          final elRight = el.boundingBox.right.toDouble();
          return elLeft >= iv.start && elRight <= iv.end;
        }).toList();
        blocks.add(Block(
          left: iv.start,
          right: iv.end,
          top: rowTop,
          bottom: rowBottom,
          elements: elemsInBlock,
          row: rowIdx,
          col: colIdx,
        ));
      }
      for (int colIdx = 0; colIdx < emptyXIntervals.length; colIdx++) {
        final iv = emptyXIntervals[colIdx];
        blocks.add(Block(
          left: iv.start,
          right: iv.end,
          top: rowTop,
          bottom: rowBottom,
          elements: [],
          row: rowIdx,
          col: mergedXIntervals.length + colIdx,
        ));
      }

      // 按left排序
      blocks.sort((a, b) => a.left.compareTo(b.left));
      blocksAllRows[rowIdx] = blocks;

      print('[GridDebug] 行$rowIdx blocks: ${blocks.map((b) => '[${b.left.toStringAsFixed(0)}, ${b.right.toStringAsFixed(0)}]${b.elements.isEmpty ? "(空)" : "(${b.elements.length})"}').toList()}');
    }

    print('[GridDebug] 最终行中心: $rowCenters');
    print('[GridDebug] 最终行边界线: $yBoundariesList');

    // 扁平化所有blocks为一个列表
    final allBlocks = <Block>[];
    for (final rowBlocks in blocksAllRows.values) {
      allBlocks.addAll(rowBlocks);
    }
    return allBlocks;
  }


  /// 构建布局矩阵
  Map<String, String> buildLayoutMatrix(
    RecognizedText result,
    Map<String, dynamic> gridInfo,
  ) {
    final namePattern = RegExp(r'^\d+-\d+[CK]LP\d+$');
    final rowCenters = gridInfo['rowCenters'] as List<double>;
    final colCenters = gridInfo['colCenters'] as List<double>;
    final matrix = <String, String>{};

    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final text = element.text.trim();
          if (namePattern.hasMatch(text)) {
            final cx = (element.boundingBox.left + element.boundingBox.right) / 2;
            final cy = (element.boundingBox.top + element.boundingBox.bottom) / 2;
            final row = _findNearestIndex(cy, rowCenters);
            final col = _findNearestIndex(cx, colCenters);
            if (row >= 0 && col >= 0) {
              matrix['$row-$col'] = text;
            }
          }
        }
      }
    }
    return matrix;
  }

  int _findNearestIndex(double value, List<double> centers) {
    if (centers.isEmpty) return -1;
    int best = 0;
    double bestDist = (value - centers[0]).abs();
    for (int i = 1; i < centers.length; i++) {
      final dist = (value - centers[i]).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = i;
      }
    }
    return best;
  }

  /// 处理图像并返回识别结果
  Future<RecognizedText> processImage(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    return await _textRecognizer.processImage(inputImage);
  }

  /// 扫描单个格子区域，返回识别结果
  Future<RecognizedText?> scanRegion(
    File imageFile,
    Size originalImageSize,
    double top,
    double left,
    double bottom,
    double right,
  ) async {
    try {
      const paddingFactor = 0.1;
      final padX = (right - left) * paddingFactor;
      final padY = (bottom - top) * paddingFactor;
      final cropTop = (top - padY).clamp(0.0, originalImageSize.height);
      final cropLeft = (left - padX).clamp(0.0, originalImageSize.width);
      final cropBottom =
          (bottom + padY).clamp(0.0, originalImageSize.height);
      final cropRight = (right - padX).clamp(0.0, originalImageSize.width);

      final bytes = await imageFile.readAsBytes();
      final image = img.decodeImage(bytes);
      if (image == null) return null;

      final cropped = img.copyCrop(
        image,
        x: cropLeft.toInt(),
        y: cropTop.toInt(),
        width: (cropRight - cropLeft).toInt(),
        height: (cropBottom - cropTop).toInt(),
      );

      final resized = img.copyResize(
        cropped,
        width: cropped.width * 2,
        height: cropped.height * 2,
      );
      img.contrast(resized, contrast: 150);

      final tempDir = await getTemporaryDirectory();
      final tempPath = '${tempDir.path}/region_${DateTime.now().millisecondsSinceEpoch}.jpg';
      await File(tempPath).writeAsBytes(img.encodeJpg(resized, quality: 90));

      final inputImage = InputImage.fromFilePath(tempPath);
      final result = await _textRecognizer.processImage(inputImage);
      await File(tempPath).delete();

      return result;
    } catch (e) {
      return null;
    }
  }

  /// 解析压板列表（降级方案）
  List<PressPlate> parsePressPlates(RecognizedText recognizedText) {
    final plates = <PressPlate>[];
    final namePattern = RegExp(r'^(\d+-\d+[CK]LP\d+)$');

    final elements = <TextElement>[];
    for (final block in recognizedText.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final text = element.text.trim();
          if (text.isNotEmpty) {
            elements.add(TextElement(
              text: text,
              boundingBox: element.boundingBox,
            ));
          }
        }
      }
    }
    if (elements.isEmpty) return plates;

    const rowThreshold = 30.0;
    final sortedByY = elements.toList()
      ..sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));
    final rows = <List<TextElement>>[];
    var currentRow = <TextElement>[sortedByY.first];
    var lastY = sortedByY.first.boundingBox.top;
    for (var i = 1; i < sortedByY.length; i++) {
      final element = sortedByY[i];
      if ((element.boundingBox.top - lastY).abs() < rowThreshold) {
        currentRow.add(element);
      } else {
        rows.add(currentRow);
        currentRow = [element];
        lastY = element.boundingBox.top;
      }
    }
    rows.add(currentRow);

    for (final row in rows) {
      row.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
      String? currentPlateName;
      final descriptions = <String>[];
      for (final element in row) {
        final text = element.text;
        final match = namePattern.firstMatch(text);
        if (match != null) {
          if (currentPlateName != null) {
            plates.add(PressPlate(
              name: currentPlateName,
              description: descriptions.join(" "),
            ));
          }
          currentPlateName = match.group(1);
          descriptions.clear();
        } else if (currentPlateName != null) {
          descriptions.add(text);
        }
      }
      if (currentPlateName != null) {
        plates.add(PressPlate(
          name: currentPlateName,
          description: descriptions.join(" "),
        ));
      }
    }

    plates.sort((a, b) {
      final aBox = elements
          .firstWhere((e) => e.text == a.name || namePattern.hasMatch(e.text))
          .boundingBox;
      final bBox = elements
          .firstWhere((e) => e.text == b.name || namePattern.hasMatch(e.text))
          .boundingBox;
      final rowCompare = aBox.top.compareTo(bBox.top);
      if (rowCompare != 0) return rowCompare;
      return aBox.left.compareTo(bBox.left);
    });

    _assignRowCol(plates, elements, namePattern);
    return plates;
  }

  void _assignRowCol(
    List<PressPlate> plates,
    List<TextElement> elements,
    RegExp namePattern,
  ) {
    if (plates.isEmpty) return;
    final plateYPositions = <double>[];
    for (final plate in plates) {
      final element = elements.firstWhere(
        (e) => namePattern.hasMatch(e.text),
        orElse: () => elements.first,
      );
      plateYPositions.add(element.boundingBox.top);
    }
    const rowThreshold = 30.0;
    final uniqueYValues = <double>[plateYPositions.first];
    for (final y in plateYPositions) {
      var found = false;
      for (final uy in uniqueYValues) {
        if ((y - uy).abs() < rowThreshold) {
          found = true;
          break;
        }
      }
      if (!found) uniqueYValues.add(y);
    }
    uniqueYValues.sort();
    for (final plate in plates) {
      final element = elements.firstWhere(
        (e) => namePattern.hasMatch(e.text),
        orElse: () => elements.first,
      );
      final plateY = element.boundingBox.top;
      for (var i = 0; i < uniqueYValues.length; i++) {
        if ((plateY - uniqueYValues[i]).abs() < rowThreshold) {
          plate.row = i + 1;
          break;
        }
      }
    }
    final platesByRow = <int, List<PressPlate>>{};
    for (final plate in plates) {
      platesByRow.putIfAbsent(plate.row, () => []).add(plate);
    }
    for (final row in platesByRow.values) {
      row.sort((a, b) {
        final aIdx = elements.indexWhere(
          (e) => namePattern.hasMatch(e.text) && e.text == a.name,
        );
        final bIdx = elements.indexWhere(
          (e) => namePattern.hasMatch(e.text) && e.text == b.name,
        );
        if (aIdx == -1 || bIdx == -1) return 0;
        return elements[aIdx].boundingBox.left
            .compareTo(elements[bIdx].boundingBox.left);
      });
      for (var i = 0; i < row.length; i++) {
        row[i].col = i + 1;
      }
    }
  }
}


class TextElement {
  final String text;
  final Rect boundingBox;
  final double? confidence;
  TextElement({required this.text, required this.boundingBox, this.confidence});

  double get cx => (boundingBox.left + boundingBox.right) / 2;
  double get cy => (boundingBox.top + boundingBox.bottom) / 2;
}
