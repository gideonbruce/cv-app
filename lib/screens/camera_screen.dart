import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:computer_vision_app/screens/gallery_screen.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  //Interpreter? _interpreter;
  //bool _isModelLoaded = false;
  //List<Map<String, dynamic>> _detections = [];
  //const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
  //super.iniState();
  //_loadModel();
}

Uint8List _imageToByteBuffer(img.Image image) {
  int width = image.width;
  int height = image.height;
  var buffer = Uint8List(width * height * 3); // RGB channels
  int index = 0;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      img.Pixel pixel = image.getPixel(x, y);

      buffer[index++] = pixel.r.toInt();
      buffer[index++] = pixel.g.toInt();
      buffer[index++] = pixel.b.toInt();
    }
  }

  return buffer;
}

Uint8List _convertYUV420toRGB(CameraImage image) {
  final int width = image.width;
  final int height = image.height;
  final int yRowStride = image.planes[0].bytesPerRow;
  final int uvRowStride = image.planes[1].bytesPerRow;
  final int uvPixelStride = image.planes[1].bytesPerPixel!;

  Uint8List yBuffer = image.planes[0].bytes;
  Uint8List uBuffer = image.planes[1].bytes;
  Uint8List vBuffer = image.planes[2].bytes;

  List<int> rgbPixels = List.filled(width * height * 3, 0);

  int uvIndex = 0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int yIndex = y * yRowStride + x;

      int yValue = yBuffer[yIndex] & 0xFF;
      int uValue = uBuffer[uvIndex] & 0xFF;
      int vValue = vBuffer[uvIndex] & 0xFF;

      if (x % 2 == 1) {
        uvIndex += uvPixelStride;
      }

      int r = (yValue + (1.370705 * (vValue - 128))).round().clamp(0, 255);
      int g = (yValue - (0.698001 * (vValue - 128)) - (0.337633 * (uValue - 128))).round().clamp(0, 255);
      int b = (yValue + (1.732446 * (uValue - 128))).round().clamp(0, 255);

      int pixelIndex = (y * width + x) * 3;
      rgbPixels[pixelIndex] = r;
      rgbPixels[pixelIndex + 1] = g;
      rgbPixels[pixelIndex + 2] = b;
    }
    if (y % 2 == 1) {
      uvIndex += uvRowStride - (width ~/ 2) * uvPixelStride;
    }
  }

  return Uint8List.fromList(rgbPixels);
}

Interpreter? _interpreter;
bool _isModelLoaded = false;

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> cameras = [];
  bool _isInitialized = false;
  late Interpreter _interpreter;
  bool _isBusy = false;
  //List<dynamic> _detections = [];
  bool _isCapturing = false;

  final cloudinary = CloudinaryPublic('daq0tdpcm', 'flutterr', cache: false);

  List<Map<String, dynamic>> _detections = [];
  DateTime _lastCaptureTime = DateTime.now();
  DateTime _lastProcessTime = DateTime.now();

  static const Duration minCaptureInterval = Duration(seconds: 2);
  static const Duration minProcessInterval = Duration(milliseconds: 500);

  void _runInference(CameraImage cameraImage) async {
    if (!_isModelLoaded) return;

    Uint8List imageBytes = _convertYUV420toRGB(cameraImage);

    img.Image image = img.decodeImage(imageBytes)!;
    img.Image resizedImage = img.copyResize(image, width: 300, height: 300);

    Uint8List inputBuffer = _imageToByteBuffer(resizedImage);

    var outputBuffer = List.generate(1, (index) => List.filled(10, 0.0));

    _interpreter!.run(inputBuffer, outputBuffer);  //matching output buffer
    List<Map<String, dynamic>> detections = _postProcessResults(outputBuffer);

    if (mounted) {
      setState(() {
        _detections = detections;
      });
    }

    if (_detections.isNotEmpty) {
      _captureAndSaveImage(); // Capture image if detection is found
    }


  }
  //List<Map<String, dynamic>> _postProcessResults(List<List<double>> output) {
    //return output.map((o) => {'label': 'Object', 'confidence': o[0]}).toList();
  //}

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
  final confidenceThreshold = 0.25;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/best.tflite');
      setState(() {
        _isModelLoaded = true;
      });
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

        await _controller!.startImageStream(
            _processCameraImage
        );
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
    if (_isBusy || !_isModelLoaded) return;
    _isBusy = true;

    try {
      // Run inference
      final detections = await _detectWeeds(image);
      if (mounted) {
        setState(() {
          _detections = detections;
        });
        if (_detections.isNotEmpty) {
          _captureAndSaveImage();
        }
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isBusy = false;
    }
    _isBusy = false;
  }


  Future<List<Map<String, dynamic>>> _detectWeeds(CameraImage image) async {
    if (_interpreter == null) return [];

    try {
      final inputArray = await _preProcessImage(image);

      final outputBuffer = List.generate(
        1,
          (_) => List.generate(
            6,
              (_) => List.filled(8400, 0.0),
          ),
      );

      //run inference
      _interpreter!.run(inputArray, outputBuffer);

      //process output tensor
      return _postProcessResults(outputBuffer[0]);
    } catch (e) {
      debugPrint('Inference error: $e');
      return [];
    }
  }

  Future<List<List<List<List<double>>>>> _preProcessImage(CameraImage image) async {
    final inputSize = 640;
    final inputArray = List.generate(1, (_) =>
        List.generate(inputSize, (_) =>
            List.generate(inputSize, (_) =>
                List.generate(3, (_) => 0.0)
            )
        )
    );

    final bytes = image.planes[0].bytes;
    final stride = image.planes[0].bytesPerRow;

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        final pixel = bytes[y * stride + x];

        /*final r = (pixel & 0xFF0000) >> 16;
        final g = (pixel & 0x00FF00) >> 8;
        final b = (pixel & 0x0000FF);*/

        // scaled coordinates
        final newX = (x * inputSize / image.width).toInt();
        final newY = (y * inputSize / image.height).toInt();


        if (newX < inputSize && newY < inputSize) {
          inputArray[0][newY][newX][0] = (pixel & 0xFF) / 255.0; //R
          inputArray[0][newY][newX][1] = ((pixel >> 8) & 0xFF) / 255.0; //G
          inputArray[0][newY][newX][2] = ((pixel >> 16) & 0xFF) / 255.0; //B
        }

      }
    }

    return inputArray;
  }

  List<Map<String, dynamic>> _postProcessResults(List<List<double>> output) {
    final List<Map<String, dynamic>> detections = [];

    for (int i = 0; i < 8400; i++) {
      final double confidence = output[4][i]; // Confidence score

      if (confidence > confidenceThreshold) {
        final double x = output[0][i]; // X-coordinate of the box
        final double y = output[1][i]; // Y-coordinate of the box
        final double w = output[2][i]; // Width of the box
        final double h = output[3][i]; // Height of the box

        final double classScore = output[5][i];

        detections.add({
          'box': [x, y, w, h],
          'confidence': confidence,
          'label': labels[0],
          'class_score': classScore
        });
      }
    }

    return detections;
  }


  /*List<Map<String, dynamic>> _postProcessResults(List<double> outputs) {
    final List<Map<String, dynamic>> detections = [];
    final int numDetections = outputs.length ~/ 7;

    for (int i = 0; i < numDetections; i++) {
      final double xCenter = outputs[i + 7];
      final double yCenter = outputs[i * 7 + 1];
      final double w = outputs[i * 7 + 2];
      final double h = outputs[i * 7 + 3];
      final double confidence = outputs[i * 7 + 4];

      if (confidence > confidenceThreshold) {
        final int classIndex = outputs.sublist(i * 7 + 5, i * 7 + 7)
            .indexOf(outputs[i * 7 + 5]);

        detections.add({
          'box': [xCenter, yCenter, w, h],
          'confidence': confidence,
          'label': labels[classIndex],
        });
      }
    }

    return detections;
  }*/

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
