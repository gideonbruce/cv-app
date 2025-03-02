import 'package:cloudinary_public/cloudinary_public.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'dart:io';
import 'dart:isolate';
import 'dart:async';
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

class _CameraScreenState extends State<CameraScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  List<CameraDescription> cameras = [];
  bool _isInitialized = false;
  late Interpreter _interpreter;
  bool _isBusy = false;
  bool _isModelLoaded = false;
  bool _isCapturing = false;
  CameraImage? _latestImage;
  Timer? _processingTimer;

  late DateTime _lastProcessTime = DateTime.now();

  final cloudinary = CloudinaryPublic('daq0tdpcm', 'flutterr', cache: false);

  List<Map<String, dynamic>> _detections = [];

  DateTime _lastCaptureTime = DateTime.now().subtract(const Duration(seconds: 2));
  //DateTime _lastProcessTime = DateTime.now();

  static const Duration minCaptureInterval = Duration(seconds: 2);
  static const Duration minProcessInterval = Duration(seconds: 3);

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

  // Coordinate transformation
  Size? previewSize;
  double? previewRatio;
  Size? screenSize;
  double? screenRatio;
  bool isLandscape = false;

  // YOLO model configurations
  final modelPath = 'assets/best.tflite';
  final labels = ['crop', 'weed'];
  final inputSize = 416;
  final confidenceThreshold = 0.3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
    _loadModel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _stopCamera() async {
    _processingTimer?.cancel();
    if (_controller != null) {
      if (_controller!.value.isStreamingImages) {
        await _controller!.stopImageStream();
      }
      await _controller!.dispose();
      _controller = null;
    }
  }

  /*void _stopCamera() {
    _processingTimer?.cancel();
    _controller?.stopImageStream();
    _controller?.dispose();
    _controller = null;
  }*/

  Future<void> _loadModel() async {
    try {
      final options = InterpreterOptions()
        ..threads = 4;
        //..useNnapi = true;

      _interpreter = await Interpreter.fromAsset('assets/best.tflite', options: options);
      if (mounted) setState(() => _isModelLoaded = true);
      debugPrint("Model Loaded succesfully");

    } catch (e) {
      debugPrint("Error loading model: $e");
    }
  }


  Future<void> _initializeCamera() async {

    await _stopCamera();

    try {
      cameras = await availableCameras();
      final backCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      await _controller!.initialize();

      if (mounted) {
        setState(() =>
          _isInitialized = true);
        await _controller!.startImageStream(_throttledImageProcessor);
      }
    } catch (e) {
      debugPrint('Error initializing camera: $e');
    }
  }

      //Throttled image processor
  void _throttledImageProcessor(CameraImage image) {
      final now = DateTime.now();
      if (now.difference(_lastProcessTime) < minProcessInterval) return;
      _lastProcessTime = now;
      _processCameraImage(image);
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
        setState(() =>
          _detections = detections);

        final now = DateTime.now();
        if (detections.isNotEmpty &&
            now.difference(_lastCaptureTime) >= minCaptureInterval
        ) {
          _lastCaptureTime = now;
          _captureAndSaveImage();
        }
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isBusy = false;
    }
    //_isBusy = false;
  }


  Future<List<Map<String, dynamic>>> _detectWeeds(CameraImage image) async {
    if (_interpreter == null) return [];

    try {
      final inputArray = await _preProcessImage(image);

      final outputBuffer = List.generate(
        1,
          (_) => List.generate(
            6,
              (_) => List.filled(8400, 0.0)
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
    final numBoxes = output[0].length;

    for (int i = 0; i < numBoxes; i++) {
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

  Future<void> _captureAndSaveImage() async {
    if (_isCapturing) return;
    _isCapturing = true;

    try {
      final XFile image = await _controller!.takePicture();
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime
          .now()
          .millisecondsSinceEpoch;
      final weedDirectory = Directory('${directory.path}/weed_images');

      if (!await weedDirectory.exists()) {
        await weedDirectory.create();
      }

      final String imagePath = path.join(
          weedDirectory.path, 'weed_$timestamp.jpg');
      await File(image.path).copy(imagePath);

      _uploadToCloudinary(imagePath, timestamp);
    } catch (e) {
      debugPrint('Error capturing image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Error saving image')),
        );
      }
    } finally {
      _isCapturing = false;
    }
  }

  void _scheduledUpload(String imagePath, int timestamp) {
    Future.delayed(const Duration(seconds: 2), () {
      _uploadToCloudinary(imagePath, timestamp);
    });
  }

  //separate method for background upload
  Future<void> _uploadToCloudinary(String imagePath, int timestamp) async {
    try {
      final response = await cloudinary.uploadFile(
        CloudinaryFile.fromFile(imagePath, resourceType: CloudinaryResourceType.Image),
      );

      final metadataPath = path.join(
        path.dirname(imagePath),
        'weed_${timestamp}_metadata.json'
      );

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
            content: Text('Uploaded: ${path.basename(imagePath)}'),
            duration: const Duration(seconds: 1),
          ),
        );
      }
    } catch (e) {
      debugPrint('Upload error: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _processingTimer?.cancel();
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
                    isLandscape: MediaQuery.of(context).orientation == Orientation.landscape,
                    //transformBoundingBox: _transformBoundingBox,
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
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'Crops: ${_detections.where((d) => d['label'] == 'crop').length}',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                        Text(
                          'Weeds: ${_detections.where((d) => d['label'] == 'weed').length}',
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ],
                    ),
                    /*Text(
                      '${_detections.length} weeds detected',
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),*/
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
  //final Function(List<double>, Size) transformBoundingBox;

  BoundingBoxPainter({
    required this.detections,
    required this.previewSize,
    required this.isLandscape,
    //required this.transformBoundingBox,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final Map<String, Color> classColors = {
      'crop': Colors.blue,
      'weed': Colors.red,
    };

    final labelPaint = Paint()
      ..color = Colors.black.withOpacity(0.5)
      ..style = PaintingStyle.fill;

    for (final detection in detections) {
      final box = detection['box'] as List<double>;
      final confidence = detection['confidence'] as double;
      final label = detection['label'] as String;

      // setting color based on class
      final paint = Paint()
        ..color = classColors[label] ?? Colors.green
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
      ;

      final rect = Rect.fromLTWH(
        box[0] * size.width,
        box[1] * size.height,
        box[2] * size.width,
        box[3] * size.height,
      );

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
