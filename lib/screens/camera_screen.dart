import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'package:computer_vision_app/screens/gallery_screen.dart';

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
  final cloudinary = CloudinaryPublic('daq0tdpcm', 'flutterr', cache: false);


  // Coordinate transformation
  Size? previewSize;
  double? previewRatio;
  Size? screenSize;
  double? screenRatio;
  bool isLandscape = false;

  // YOLO model configurations
  final modelPath = 'assets/best.tflite';
  final labels = ['weed'];
  final inputSize = 416;
  final confidenceThreshold = 0.005;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }


  //Future<void> _loadModel() async {
   // try {
      //final options = InterpreterOptions();
      //_interpreter = await Interpreter.fromAsset(modelPath, options: options);
      //debugPrint('Model loaded successfully');
    //} catch (e) {
      //debugPrint('Error loading model: $e');
    //}
  //}
  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('best.tflite');
      debugPrint("Model loaded successfully");
    } catch (e) {
      debugPrint("Error loading model: $e");
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
    final int numDetections = outputs.length ~/ 7;

    for (int i = 0; i < numDetections; i++) {
      final double xCenter = outputs[i + 7];
      final double yCenter = outputs[i * 7 + 1];
      final double w = outputs[i * 7 + 2];
      final double h = outputs[i * 7 + 3];
      final double confidence = outputs[i * 7 + 4];
      if (confidence > 0.01) {
        final int classIndex = outputs.sublist(i * 7 + 5, i * 7 + 7).indexOf(outputs[i * 7 + 5]);

        detections.add({
          'box': [xCenter, yCenter, w, h],
          'confidence': confidence,
          'label': labels[classIndex],
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

        // 🔹 Upload Image to Cloudinary
        CloudinaryResponse response = await cloudinary.uploadFile(
          CloudinaryFile.fromFile(imagePath, resourceType: CloudinaryResourceType.Image),
        );

        // 🔹 Save Metadata with Cloudinary URL
        final metadataPath = path.join(weedDirectory.path, 'weed_${timestamp}_metadata.json');
        await File(metadataPath).writeAsString('''
      {
        "timestamp": "$timestamp",
        "cloudinary_url": "${response.secureUrl}",
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
              content: Text('Uploaded & Saved: ${path.basename(imagePath)}'),
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
            content: Text('Error saving/uploading image'),
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
          fit: StackFit.expand,
          children: [
            // Camera Preview
            AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CameraPreview(_controller!),
            ),

            // bounding box overlay
            LayoutBuilder(
              builder: (context, constraints) {
                return CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: BoundingBoxPainter(
                    detections: _detections,
                    previewSize: Size(constraints.maxWidth, constraints.maxHeight),
                    isLandscape: isLandscape,
                    transformBoundingBox: _transformBoundingBox,
                  ),
                );
              },
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
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (context) => GalleryScreen()),
                        );
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
  final bool isLandscape;
  final Function(List<double>, Size) transformBoundingBox;

  BoundingBoxPainter({
    required this.detections,
    required this.previewSize,
    required this.isLandscape,
    required this.transformBoundingBox,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final labelPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    for (final detection in detections) {
      final box = detection['box'] as List<double>;
      final confidence = detection['confidence'] as double;
      final label = detection['label'] as String;
      //final rect = Rect.fromLTWH(
      //box[0] * size.width,
      //box[1] * size.height,
      //box[2] * size.width,
      //box[3] * size.height,
      //);

      final rect = transformBoundingBox(box, size);

      //draw bounding box
      canvas.drawRect(rect, paint);

      // draw label background
      final labelText = '$label ${(confidence * 100).toStringAsFixed(0)}%';
      final textSpan = TextSpan(
        text: labelText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      //draw label background
      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top - 22,
        textPainter.width + 8,
        22,
      );
      canvas.drawRect(labelRect, labelPaint);

      //draw label text
      textPainter.paint(
        canvas,
        Offset(rect.left + 4, rect.top - 20),
      );
    }
  }

  @override
  bool shouldRepaint(BoundingBoxPainter oldDelegate) =>
      detections != oldDelegate.detections;

}



