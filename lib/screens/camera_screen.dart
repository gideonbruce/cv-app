import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> cameras = [];
  bool _isInitialized = false;
  late Interpreter _interpreter;
  bool _isBusy = false;
  List<dynamic> _detections = [];
  bool _isCapturing = false;

  // Coordinate transformation
  Size? previewSize;
  double? previewRatio;
  Size? screenSize;
  double? screenRatio;
  bool isLandscape = false;

  // YOLO model configurations
  final modelPath = 'assets/weed_detection.tflite';
  final labels = ['weed'];
  final inputSize = 416;
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
      debugPrint('Model loaded successfully');
    } catch (e) {
      debugPrint('Error loading model: $e');
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
          previewSize = Size(
            _controller!.value.previewSize!.height,
            _controller!.value.previewSize!.width,
          );
          previewRatio = previewSize!.width / previewSize!.height;
        });

        await _controller!.startImageStream(_processCameraImage);
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

  // Method to transform coordinates
  Rect _transformBoundingBox(List<double> box, Size size) {
    //converting normalized coordinates to actual coordinates
    final double x = box[0] * size.width;
    final double y = box[1] * size.height;
    final double w = box[2] * size.width;
    final double h = box[3] * size.height;

    //adjusting screen orientation and aspect ratio
    if (isLandscape) {
      return Rect.fromLTWH(x, y, w, h);
    } else {
      //for portrait swap coordinates
      return Rect.fromLTWH(
        size.width - (y + h),  //adjusting x coordinate
        x,      //use original x as y
        h,     //swap width and height
        w,
      );
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
      debugPrint('Error processing image: $e');
    }

    _isBusy = false;
  }

  Future<List<Map<String, dynamic>>> _detectWeeds(CameraImage image) async {
    final inputArray = await _preProcessImage(image);

    final outputShape = _interpreter.getOutputTensor(0).shape;
    final outputBuffer = List<double>.filled(outputShape.reduce((a, b) => a * b), 0);

    final inputs = [inputArray];
    final outputs = [outputBuffer];

    _interpreter.run(inputs, outputs);

    return _postProcessResults(outputs[0]);
  }

  Future<List<double>> _preProcessImage(CameraImage image) async {
    final inputArray = List<double>.filled(inputSize * inputSize * 3, 0);

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

    for (var i = 0; i < outputs.length; i += 85) {
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

  Future<void> _captureAndSaveImage() async {
    if (_isCapturing || _controller == null || !_controller!.value.isInitialized) {
      return;
    }

    setState(() {
      _isCapturing = true;
    });

    try {
      final XFile image = await _controller!.takePicture();

      if (_detections.isNotEmpty) {
        final directory = await getApplicationDocumentsDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;

        final weedDirectory = Directory('${directory.path}/weed_images');
        if (!await weedDirectory.exists()) {
          await weedDirectory.create();
        }

        final String imagePath = path.join(weedDirectory.path, 'weed_$timestamp.jpg');
        await File(image.path).copy(imagePath);

        final metadataPath = path.join(weedDirectory.path, 'weed_${timestamp}_metadata.json');
        await File(metadataPath).writeAsString('''
        {
          "timestamp": "$timestamp",
          "detections": ${_detections.map((d) => {
          "confidence": d['confidence'],
          "box": d['box'],
          "label": d['label']
        }).toList()}
        }
        ''');

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Saved: ${path.basename(imagePath)}'),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('Error capturing image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Error saving image'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isCapturing = false;
        });
      }
    }
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
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    //get screen size and update ratios
    screenSize = MediaQuery.of(context).size;
    screenRatio = screenSize!.width / screenSize!.height;
    isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            // Camera Preview
            CameraPreview(_controller!),

            // Bounding Boxes
            CustomPaint(
              painter: BoundingBoxPainter(
                detections: _detections,
                previewSize: Size(
                  _controller!.value.previewSize!.height,
                  _controller!.value.previewSize!.width,
                ),
              ),
            ),

            // Top Bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                color: Colors.black45,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Text(
                      '${_detections.length} weeds detected',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder, color: Colors.white),
                      onPressed: () {
                        // TODO: Navigate to gallery
                      },
                    ),
                  ],
                ),
              ),
            ),

            // Capture Button
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isCapturing)
                    const CircularProgressIndicator(color: Colors.white)
                  else
                    FloatingActionButton(
                      onPressed: _detections.isNotEmpty ? _captureAndSaveImage : null,
                      backgroundColor: _detections.isNotEmpty ? Colors.white : Colors.grey,
                      child: Icon(
                        Icons.camera,
                        color: _detections.isNotEmpty ? Colors.black : Colors.white,
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
}

class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detections;
  final Size previewSize;

  BoundingBoxPainter({
    required this.detections,
    required this.previewSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final detection in detections) {
      final box = detection['box'] as List<double>;
      final rect = Rect.fromLTWH(
        box[0] * size.width,
        box[1] * size.height,
        box[2] * size.width,
        box[3] * size.height,
      );

      canvas.drawRect(rect, paint);

      final textPainter = TextPainter(
        text: TextSpan(
          text: '${detection['label']} ${(detection['confidence'] * 100).toStringAsFixed(0)}%',
          style: const TextStyle(
            color: Colors.green,
            fontSize: 12,
            backgroundColor: Colors.black54,
          ),
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