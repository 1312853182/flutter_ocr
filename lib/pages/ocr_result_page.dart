import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/press_plate.dart';
import '../ocr_channel.dart';
import '../services/ocr_service.dart';
import '../widgets/group_overlay_painter.dart';

const _namePattern = r'^\d+-\d+[CK]LP\d+$';

class OcrResultPage extends StatefulWidget {
  final String imagePath;

  const OcrResultPage({super.key, required this.imagePath});

  @override
  State<OcrResultPage> createState() => _OcrResultPageState();
}

class _OcrResultPageState extends State<OcrResultPage>
    with SingleTickerProviderStateMixin {
  final OcrService _ocrService = OcrService();
  late final TabController _tabController;

  File? _selectedImage;
  String _recognizedText = "";
  RecognizedText? _fullRecognizedText;
  List<PressPlate> _pressPlates = [];
  List<TextGroup> _textGroups = [];
  bool _isRecognizing = false;
  Size? _originalImageSize;
  Size? _displayImageSize;
  List<Map<String, dynamic>> _blocks = [];
  bool _showOverlay = true;

  // 分区域扫描相关
  bool _isScanningRegions = false;
  int _regionScanProgress = 0;
  int _regionScanTotal = 0;
  final Map<String, RecognizedText> _regionScanResults = {};

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _selectedImage = File(widget.imagePath);
    _loadImageSize();
  }

  Future<void> _loadImageSize() async {
    final bytes = await _selectedImage!.readAsBytes();
    final decodedImage = await decodeImageFromList(bytes);
    setState(() {
      _originalImageSize = Size(
        decodedImage.width.toDouble(),
        decodedImage.height.toDouble(),
      );
    });
  }

  @override
  void dispose() {
    _ocrService.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // ==================== 文字识别 ====================

  Future<void> _recognizeText() async {
    if (_selectedImage == null || _isRecognizing) return;

    setState(() => _isRecognizing = true);

    try {
      final recognizedText = await _ocrService.processImage(_selectedImage!);

      final blocksResult =
          _ocrService.buildGridFromClusters(recognizedText, _originalImageSize!);
      _blocks = blocksResult.map((b) => {
        'left': b.left,
        'right': b.right,
        'top': b.top,
        'bottom': b.bottom,
        'row': b.row,
        'col': b.col,
        'elements': b.elements.map((e) => {
          'text': e.text,
          'left': e.boundingBox.left.toDouble(),
          'top': e.boundingBox.top.toDouble(),
          'right': e.boundingBox.right.toDouble(),
          'bottom': e.boundingBox.bottom.toDouble(),
          'confidence': e.confidence,
        }).toList(),
      }).toList();

      List<PressPlate> plates;
      List<TextGroup> groups;

      if (_blocks.isNotEmpty) {
        plates = _extractPlatesFromBlocks();
        groups = _groupTextElements(recognizedText);
      } else {
        groups = _groupTextElements(recognizedText);
        plates = _ocrService.parsePressPlates(recognizedText);
      }

      setState(() {
        _recognizedText = recognizedText.text;
        _fullRecognizedText = recognizedText;
        _pressPlates = plates;
        _textGroups = groups;
      });

      // 解析完成后切换到"全部识别"tab
      _tabController.animateTo(2);
    } catch (e, stackTrace) {
      print('识别失败: $e\n$stackTrace');
      // 截取错误信息的前200字符显示
      final errorMsg = e.toString();
      final displayMsg = errorMsg.length > 200
          ? '${errorMsg.substring(0, 200)}\n...(更多内容见日志)'
          : errorMsg;
      _showMessage('识别失败: $displayMsg');
    } finally {
      setState(() => _isRecognizing = false);
    }
  }

  List<PressPlate> _extractPlatesFromBlocks() {
    final plates = <PressPlate>[];
    for (final block in _blocks) {
      final elems = block['elements'] as List<Map<String, dynamic>>;
      for (final elem in elems) {
        final text = elem['text'] as String;
        final match = RegExp(_namePattern).firstMatch(text);
        if (match != null) {
          plates.add(PressPlate(
            name: match.group(0)!,
            description: '',
            row: (block['row'] as int) + 1,
            col: (block['col'] as int) + 1,
          ));
        }
      }
    }
    plates.sort((a, b) => a.row != b.row ? a.row.compareTo(b.row) : a.col.compareTo(b.col));
    return plates;
  }

  // ==================== 分区域补扫 ====================

  Future<void> _regionScanOCR() async {
    if (_selectedImage == null || _isRecognizing || _fullRecognizedText == null) return;

    setState(() {
      _isScanningRegions = true;
      _regionScanProgress = 0;
      _regionScanResults.clear();
    });

    try {
      if (_blocks.isEmpty) {
        _showMessage('未检测到压板名称，无法构建网格');
        return;
      }

      final cellsToRescan = _findCellsToRescan();
      if (cellsToRescan.isEmpty) {
        _showMessage('所有压板已识别，无需补扫');
        return;
      }

      await _performRescan(cellsToRescan);

      if (_regionScanResults.isNotEmpty) {
        _showMessage('补扫完成，新增 ${_regionScanResults.length} 个压板');
        _mergeRescanResults();
      }
    } catch (e, stackTrace) {
      print('分区域扫描失败: $e\n$stackTrace');
      _showMessage('分区域扫描失败: $e');
    } finally {
      setState(() => _isScanningRegions = false);
    }
  }

  List<Map<String, dynamic>> _findCellsToRescan() {
    final nonEmptyBlocks = _blocks.where((b) => (b['elements'] as List).isNotEmpty).toList();
    if (nonEmptyBlocks.length < 2) {
      _showMessage('非空块数量不足，无法确定补扫阈值');
      return [];
    }

    final widths = nonEmptyBlocks.map((b) => (b['right'] as double) - (b['left'] as double)).toList()..sort();
    final halfCount = (nonEmptyBlocks.length / 2).ceil();
    final widthThreshold = widths[halfCount - 1];

    return _blocks.where((block) {
      final blockWidth = (block['right'] as double) - (block['left'] as double);
      return (block['elements'] as List).isEmpty && blockWidth > widthThreshold;
    }).toList();
  }

  Future<void> _performRescan(List<Map<String, dynamic>> cellsToRescan) async {
    _regionScanTotal = cellsToRescan.length;
    for (final cell in cellsToRescan) {
      final result = await _ocrService.scanRegion(
        _selectedImage!,
        _originalImageSize!,
        cell['top'],
        cell['left'],
        cell['bottom'],
        cell['right'],
      );
      if (result != null && result.text.isNotEmpty) {
        _regionScanResults['${cell['row']}-${cell['col']}'] = result;
      }
      setState(() => _regionScanProgress++);
    }
  }

  void _mergeRescanResults() {
    if (_blocks.isEmpty) return;

    for (final entry in _regionScanResults.entries) {
      final parts = entry.key.split('-');
      final row = int.parse(parts[0]);
      final col = int.parse(parts[1]);
      final result = entry.value as RecognizedText;

      final newElements = _extractNameElements(result);
      final blockIndex = _blocks.indexWhere((b) => b['row'] == row && b['col'] == col);
      if (blockIndex == -1 || newElements.isEmpty) continue;

      final targetBlock = _blocks[blockIndex];
      final blockLeft = targetBlock['left'] as double;
      final newBlocks = _createSubBlocks(targetBlock, row, blockLeft, newElements);

      _blocks.removeAt(blockIndex);
      _blocks.insertAll(blockIndex, newBlocks);
    }
    setState(() {});
  }

  List<Map<String, dynamic>> _extractNameElements(RecognizedText result) {
    final elements = <Map<String, dynamic>>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          final text = element.text.trim();
          if (RegExp(_namePattern).hasMatch(text)) {
            elements.add({
              'text': text,
              'left': element.boundingBox.left.toDouble(),
              'right': element.boundingBox.right.toDouble(),
            });
          }
        }
      }
    }
    return elements;
  }

  List<Map<String, dynamic>> _createSubBlocks(
    Map<String, dynamic> targetBlock,
    int row,
    double blockLeft,
    List<Map<String, dynamic>> newElements,
  ) {
    newElements.sort((a, b) => (a['left'] as double).compareTo(b['left'] as double));
    final mergedX = _mergeOverlappingX(newElements);

    final newBlocks = <Map<String, dynamic>>[];
    for (int i = 0; i < mergedX.length; i++) {
      final iv = mergedX[i];
      final subLeft = blockLeft + (iv['start'] as double);
      final subRight = blockLeft + (iv['end'] as double);
      final subElems = newElements.where((el) {
        return (el['left'] as double) >= (iv['start'] as double) &&
            (el['right'] as double) <= (iv['end'] as double);
      }).map((el) => el['text'] as String).toList();

      newBlocks.add({
        'left': subLeft,
        'right': subRight,
        'top': targetBlock['top'],
        'bottom': targetBlock['bottom'],
        'row': row,
        'col': i,
        'elements': subElems,
      });
    }
    return newBlocks;
  }

  List<Map<String, double>> _mergeOverlappingX(List<Map<String, dynamic>> elements) {
    final merged = <Map<String, double>>[];
    for (final el in elements) {
      final elLeft = el['left'] as double;
      final elRight = el['right'] as double;
      if (merged.isEmpty || elLeft > merged.last['end']!) {
        merged.add({'start': elLeft, 'end': elRight});
      } else {
        final lastEnd = merged.last['end']!;
        merged[merged.length - 1]['end'] = lastEnd > elRight ? lastEnd : elRight;
      }
    }
    return merged;
  }

  // ==================== 文本分组 ====================

  List<TextGroup> _groupTextElements(
    RecognizedText result, {
    double rowGapThreshold = 5.0,
    double colGapThreshold = 5.0,
  }) {
    final elements = <OcrTextElement>[];
    for (final block in result.blocks) {
      for (final line in block.lines) {
        for (final element in line.elements) {
          elements.add(OcrTextElement(
            text: element.text,
            boundingBox: element.boundingBox,
            confidence: element.confidence ?? line.confidence,
          ));
        }
      }
    }
    if (elements.isEmpty) return [];

    final rowGaps = _findGaps(elements, isVertical: true, threshold: rowGapThreshold);
    final rows = _assignElementsToRows(elements, rowGaps);

    final groups = <TextGroup>[];
    for (var rowIdx = 0; rowIdx < rows.length; rowIdx++) {
      final row = rows[rowIdx];
      if (row.isEmpty) continue;

      final colGaps = _findGaps(row, isVertical: false, threshold: colGapThreshold);
      final cols = _assignElementsToCols(row, colGaps);

      for (var colIdx = 0; colIdx < cols.length; colIdx++) {
        if (cols[colIdx].isNotEmpty) {
          groups.add(TextGroup(rowIdx, colIdx, cols[colIdx]));
        }
      }
    }
    return groups;
  }

  List<double> _findGaps(List<OcrTextElement> elements, {required bool isVertical, required double threshold}) {
    final boundaries = <double>{};
    for (final el in elements) {
      boundaries.add(isVertical ? el.boundingBox.top : el.boundingBox.left);
      boundaries.add(isVertical ? el.boundingBox.bottom : el.boundingBox.right);
    }
    final sorted = boundaries.toList()..sort();
    final gaps = <double>[];

    for (var i = 0; i < sorted.length - 1; i++) {
      final rangeStart = sorted[i];
      final rangeEnd = sorted[i + 1];
      bool hasCoverage = elements.any((el) {
        final box = el.boundingBox;
        if (isVertical) {
          return box.top <= rangeStart && box.bottom >= rangeEnd;
        } else {
          return box.left <= rangeStart && box.right >= rangeEnd;
        }
      });
      if (!hasCoverage && (rangeEnd - rangeStart) > threshold) {
        gaps.add((rangeStart + rangeEnd) / 2);
      }
    }
    return gaps;
  }

  List<List<OcrTextElement>> _assignElementsToRows(List<OcrTextElement> elements, List<double> rowGaps) {
    final rows = <List<OcrTextElement>>[];
    for (final el in elements) {
      final center = (el.boundingBox.top + el.boundingBox.bottom) / 2;
      var rowIdx = 0;
      for (var i = 0; i < rowGaps.length; i++) {
        if (center > rowGaps[i]) rowIdx = i + 1;
      }
      while (rows.length <= rowIdx) rows.add([]);
      rows[rowIdx].add(el);
    }
    return rows;
  }

  List<List<OcrTextElement>> _assignElementsToCols(List<OcrTextElement> row, List<double> colGaps) {
    final cols = <List<OcrTextElement>>[];
    for (final el in row) {
      final center = (el.boundingBox.left + el.boundingBox.right) / 2;
      var colIdx = 0;
      for (var i = 0; i < colGaps.length; i++) {
        if (center > colGaps[i]) colIdx = i + 1;
      }
      while (cols.length <= colIdx) cols.add([]);
      cols[colIdx].add(el);
    }
    return cols;
  }

  // ==================== UI辅助方法 ====================

  void _showMessage(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg)),
      );
    }
  }

  void _copyText() {
    if (_recognizedText.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _recognizedText));
    _showMessage('已复制到剪贴板');
  }

  Future<void> _sendResultToAndroid() async {
    if (_blocks.isEmpty) {
      _showMessage('没有识别数据可发送');
      return;
    }

    // 构建完整的blocks数据，包含每个元素的详细信息
    final result = _blocks.map((block) => {
      'row': block['row'],
      'col': block['col'],
      'top': block['top'],
      'bottom': block['bottom'],
      'left': block['left'],
      'right': block['right'],
      'elements': (block['elements'] as List).map((e) => {
        'text': e['text'],
        'left': e['left'],
        'top': e['top'],
        'right': e['right'],
        'bottom': e['bottom'],
        'confidence': e['confidence'],
      }).toList(),
    }).toList();

    await OcrChannel.sendResult(result);
    if (mounted) {
      _showMessage('已发送到Android，即将返回...');
      await Future.delayed(const Duration(milliseconds: 500));
      await OcrChannel.closeFlutter();
    }
  }

  // ==================== Build方法 ====================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('识别结果'),
      ),
      body: Column(
        children: [
          TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: Colors.blue,
            unselectedLabelColor: Colors.grey,
            tabs: const [
              Tab(text: '图片查看'),
              Tab(text: '全部文本'),
              Tab(text: '全部识别'),
              Tab(text: '压板识别'),
              Tab(text: '补扫结果'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                _buildImageViewTab(),
                _buildAllTextTab(),
                _buildAllOcrResultTab(),
                _buildPressPlateTab(),
                _buildRescanResultsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageViewTab() {
    return Column(
      children: [
        // 覆盖层开关
        if (_textGroups.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text('网格覆盖', style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                const SizedBox(width: 8),
                Switch(
                  value: _showOverlay,
                  onChanged: (v) => setState(() => _showOverlay = v),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ],
            ),
          ),
        // 图片区域
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey[300]!, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: _buildImageWithOverlay(),
            ),
          ),
        ),
        // 底部按钮
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              if (_fullRecognizedText == null)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _isRecognizing ? null : _recognizeText,
                    icon: _isRecognizing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.text_fields),
                    label: Text(_isRecognizing ? '解析中...' : '解析'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _copyText,
                        icon: const Icon(Icons.copy),
                        label: const Text('复制文本'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: (_isScanningRegions || _fullRecognizedText == null)
                            ? null
                            : _regionScanOCR,
                        icon: _isScanningRegions
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.grid_on),
                        label: Text(_isScanningRegions
                            ? '补扫中 $_regionScanProgress/$_regionScanTotal'
                            : '分区域补扫'),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _pressPlates.isEmpty ? null : _sendResultToAndroid,
                        icon: const Icon(Icons.send),
                        label: const Text('发送到Android'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImageWithOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final containerSize = Size(constraints.maxWidth, constraints.maxHeight);

        // 计算图片在容器中的实际显示尺寸（BoxFit.contain）
        Size displayedImageSize = containerSize;
        if (_originalImageSize != null) {
          final imageAspect = _originalImageSize!.width / _originalImageSize!.height;
          final containerAspect = containerSize.width / containerSize.height;
          if (containerAspect > imageAspect) {
            // 容器更宽，图片高度受限
            displayedImageSize = Size(
              containerSize.height * imageAspect,
              containerSize.height,
            );
          } else {
            // 容器更高，图片宽度受限
            displayedImageSize = Size(
              containerSize.width,
              containerSize.width / imageAspect,
            );
          }
        }

        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: Center(
            child: SizedBox(
              width: displayedImageSize.width,
              height: displayedImageSize.height,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.file(
                    _selectedImage!,
                    fit: BoxFit.contain,
                  ),
                  if (_showOverlay &&
                      _textGroups.isNotEmpty &&
                      _originalImageSize != null)
                    Positioned.fill(
                      child: CustomPaint(
                        painter: GroupOverlayPainter(
                          _textGroups,
                          _originalImageSize!,
                          displayedImageSize,
                          blocks: _blocks,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ==================== Tab内容构建 ====================

  Widget _buildAllTextTab() {
    if (_recognizedText.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.text_snippet, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无文本', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('点击"解析"按钮进行识别', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: SelectableText(_recognizedText, style: const TextStyle(fontSize: 14)),
    );
  }

  Widget _buildAllOcrResultTab() {
    if (_fullRecognizedText == null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.description, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无识别结果', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('点击"解析"按钮进行识别', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          ],
        ),
      );
    }

    final result = _fullRecognizedText!;
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: result.blocks.length,
      itemBuilder: (context, index) => _buildBlockCard(result.blocks[index], index + 1),
    );
  }

  Widget _buildBlockCard(dynamic block, int blockNumber) {
    final blockText = block.text.replaceAll('\n', ' ');
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              blockText,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const Divider(),
            for (var lineIdx = 0; lineIdx < block.lines.length; lineIdx++)
              _buildLineWidget(block.lines[lineIdx], lineIdx + 1),
          ],
        ),
      ),
    );
  }

  Widget _buildLineWidget(dynamic line, int lineNumber) {
    final confidence = line.confidence;
    final box = line.boundingBox;
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  line.text,
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              if (confidence != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${(confidence * 100).toInt()}%',
                    style: const TextStyle(fontSize: 11, color: Colors.blue),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                '左${box.left.toInt()} 上${box.top.toInt()} 右${box.right.toInt()} 下${box.bottom.toInt()}',
                style: TextStyle(fontSize: 10, color: Colors.grey[600]),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPressPlateTab() {
    if (_textGroups.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.grid_view, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无压板识别结果', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('点击"解析"按钮进行识别', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _textGroups.length,
      itemBuilder: (context, index) {
        final group = _textGroups[index];
        return _buildTextGroupCard(group, group.elements);
      },
    );
  }

  Widget _buildTextGroupCard(TextGroup group, List<OcrTextElement> elements) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '行:${group.row + 1}  列:${group.col + 1}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const Divider(),
            for (final el in elements)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(el.text, style: const TextStyle(fontSize: 13)),
                    ),
                    if (el.confidence != null)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${(el.confidence! * 100).toInt()}%',
                          style: const TextStyle(fontSize: 11, color: Colors.blue),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRescanResultsTab() {
    if (_regionScanResults.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 48, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无补扫结果', style: TextStyle(fontSize: 16, color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('点击"分区域补扫"按钮进行补扫', style: TextStyle(fontSize: 14, color: Colors.grey[500])),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _regionScanResults.length,
      itemBuilder: (context, index) {
        final key = _regionScanResults.keys.elementAt(index);
        final value = _regionScanResults[key]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('区域: $key', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                const Divider(),
                SelectableText(value.text, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
        );
      },
    );
  }
}