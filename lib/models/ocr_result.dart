class OcrResult {
  final String imagePath;
  final String recognizedText;
  final DateTime timestamp;

  OcrResult({
    required this.imagePath,
    required this.recognizedText,
    required this.timestamp,
  });
}
