import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> cameras = [];
  bool _isInitialized = false;
  late Interpreter _interpreter;
  bool _isBusy = false;
  List<dynamic> _detections = [];

  // YOLO model configurations
  final modelPath = 'assets/weed_detection.tflite';
  final labels = ['weed']; // Add your model's labels here
  final inputSize = 416; // YOLO typical input size
  final confidenceThreshold = 0.5;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset(modelPath, options: options);
      print('Model loaded successfully');
    } catch (e) {
      print('Error loading model: $e');
    }
  }

  Future<void> _initializeCamera() async {
    try {
      cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });

        await _controller!.startImageStream(_processCameraImage);
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  Future<void> _processCameraImage(CameraImage image) async {
    if (_isBusy) return;
    _isBusy = true;

    try {
      final detections = await _detectWeeds(image);
      if (mounted) {
        setState(() {
          _detections = detections;
        });
      }
    } catch (e) {
      print('Error processing image: $e');
    }

    _isBusy = false;
  }

  Future<List<Map<String, dynamic>>> _detectWeeds(CameraImage image) async {
    // Convert CameraImage to input tensor format
    final inputArray = await _preProcessImage(image);

    // Output tensor shapes for YOLO
    final outputShape = _interpreter.getOutputTensor(0).shape;
    final outputBuffer = List<double>.filled(outputShape.reduce((a, b) => a * b), 0);

    // Run inference
    final inputs = [inputArray];
    final outputs = [outputBuffer];

    _interpreter.run(inputs, outputs);

    // Process results
    return _postProcessResults(outputs[0]);
  }

  Future<List<double>> _preProcessImage(CameraImage image) async {
    // Convert camera image to normalized float array
    // This is a simplified version - you'll need to adjust based on your model's requirements
    final inputArray = List<double>.filled(inputSize * inputSize * 3, 0);

    // Convert YUV to RGB and normalize
    final bytes = image.planes[0].bytes;
    final stride = image.planes[0].bytesPerRow;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = bytes[y * stride + x];
        final index = (y * inputSize + x) * 3;
        inputArray[index] = pixel / 255.0;
      }
    }

    return inputArray;
  }

  List<Map<String, dynamic>> _postProcessResults(List<double> outputs) {
    final List<Map<String, dynamic>> detections = [];

    // Process YOLO outputs to get bounding boxes
    // This is a simplified version - adjust based on your model's output format
    for (var i = 0; i < outputs.length; i += 85) { // Assuming YOLO format with 85 values per detection
      final confidence = outputs[i + 4];
      if (confidence >= confidenceThreshold) {
        final x = outputs[i];
        final y = outputs[i + 1];
        final w = outputs[i + 2];
        final h = outputs[i + 3];

        detections.add({
          'box': [x, y, w, h],
          'confidence': confidence,
          'label': labels[0],
        });
      }
    }

    return detections;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _interpreter.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Weed Detection')),
      body: SafeArea(
        child: Stack(
          children: [
            CameraPreview(_controller!),
            CustomPaint(
              painter: BoundingBoxPainter(
                detectedObjects: _detections,
                previewSize: Size(
                  _controller!.value.previewSize!.height,
                  _controller!.value.previewSize!.width,
                ),
              ),
            ),
            Positioned(
              bottom: 20,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    icon: const Icon(Icons.camera),
                    color: Colors.white,
                    onPressed: () {
                      // TODO: Implement capture functionality
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detectedObjects;
  final Size previewSize;

  BoundingBoxPainter({
    required this.detectedObjects,
    required this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final detection in detectedObjects) {
      final box = detection['box'] as List<double>;
      final rect = Rect.fromLTWH(
        box[0] * size.width,
        box[1] * size.height,
        box[2] * size.width,
        box[3] * size.height,
      );

      canvas.drawRect(rect, paint);

      // Draw label
      final textPainter = TextPainter(
        text: TextSpan(
          text: '${detection['label']} ${(detection['confidence'] * 100).toStringAsFixed(0)}%',
          style: const TextStyle(color: Colors.green, fontSize: 12),
        ),
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, rect.topLeft);
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}