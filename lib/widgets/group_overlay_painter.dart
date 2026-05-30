import 'dart:ui';

import 'package:flutter/material.dart';

class TextGroup {
  final int row;
  final int col;
  final List<OcrTextElement> elements;

  TextGroup(this.row, this.col, this.elements);

  Rect get boundingBox {
    double minLeft = elements.first.boundingBox.left;
    double minTop = elements.first.boundingBox.top;
    double maxRight = elements.first.boundingBox.right;
    double maxBottom = elements.first.boundingBox.bottom;

    for (final el in elements) {
      if (el.boundingBox.left < minLeft) minLeft = el.boundingBox.left;
      if (el.boundingBox.top < minTop) minTop = el.boundingBox.top;
      if (el.boundingBox.right > maxRight) maxRight = el.boundingBox.right;
      if (el.boundingBox.bottom > maxBottom) maxBottom = el.boundingBox.bottom;
    }

    return Rect.fromLTRB(minLeft, minTop, maxRight, maxBottom);
  }
}

class OcrTextElement {
  final String text;
  final Rect boundingBox;
  final double? confidence;

  OcrTextElement({required this.text, required this.boundingBox, this.confidence});
}

class GroupOverlayPainter extends CustomPainter {
  final List<TextGroup> groups;
  final Size originalImageSize;
  final Size displaySize;
  final List<Map<String, dynamic>>? blocks;

  GroupOverlayPainter(
    this.groups,
    this.originalImageSize,
    this.displaySize, {
    this.blocks,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = displaySize.width / originalImageSize.width;
    final scaleY = displaySize.height / originalImageSize.height;

    // 绘制blocks边框线
    if (blocks != null && blocks!.isNotEmpty) {
      final blockPaint = Paint()
        ..color = Colors.yellow.withOpacity(0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;

      for (final block in blocks!) {
        final left = (block['left'] as double) * scaleX;
        final top = (block['top'] as double) * scaleY;
        final right = (block['right'] as double) * scaleX;
        final bottom = (block['bottom'] as double) * scaleY;
        canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), blockPaint);
      }
    }

    final colors = [
      Colors.red,
      Colors.blue,
      Colors.green,
      Colors.orange,
      Colors.purple,
      Colors.teal,
      Colors.pink,
      Colors.cyan,
    ];

    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      final box = group.boundingBox;

      final rect = Rect.fromLTRB(
        box.left * scaleX,
        box.top * scaleY,
        box.right * scaleX,
        box.bottom * scaleY,
      );

      final color = colors[i % colors.length];
      final bgPaint = Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.fill;
      canvas.drawRect(rect, bgPaint);

      final borderPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      canvas.drawRect(rect, borderPaint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: '${group.row + 1}-${group.col + 1}',
          style: TextStyle(
            color: color,
            fontSize: 8,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(rect.left + 2, rect.top + 2));
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
