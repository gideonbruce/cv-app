import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img_lib;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:cloudinary_public/cloudinary_public.dart';
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
  Size? previewSize;
  double? previewRatio;

  final cloudinary = CloudinaryPublic('daq0tdpcm', 'flutterr', cache: false);

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/model.tflite');
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

  void _processCameraImage(CameraImage image) {
    if (_isBusy) return;
    _isBusy = true;

    try {
      // Convert CameraImage to a format usable by TFLite
      List<int> imageBytes = _convertYUV420toRGB(image);

      // Run inference
      var input = [imageBytes]; // Adjust based on your model input
      var output = List.filled(1 * 10, 0).reshape([1, 10]); // Adjust based on model output

      _interpreter.run(input, output);

      setState(() {
        _detections = output;
      });
    } catch (e) {
      debugPrint("Error processing image: $e");
    } finally {
      _isBusy = false;
    }
  }

  List<int> _convertYUV420toRGB(CameraImage image) {
    final int width = image.width;
    final int height = image.height;
    final img_lib.Image img = img_lib.Image(width: width, height: height);

    Plane plane = image.planes[0]; // Y Plane (Luminance)
    List<int> bytes = plane.bytes;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int pixelIndex = y * width + x;
        int luminance = bytes[pixelIndex]; // Grayscale approximation
        img.setPixelRgba(x, y, luminance, luminance, luminance, 255);
      }
    }

    return img.getBytes();
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
        File imageFile = File(image.path);
        CloudinaryResponse response = await cloudinary.uploadFile(
          CloudinaryFile.fromFile(imageFile.path, resourceType: CloudinaryResourceType.Image),
        );
        print('Image uploaded: ${response.secureUrl}');
      }
    } catch (e) {
      debugPrint('Error capturing image: $e');
    } finally {
      setState(() {
        _isCapturing = false;
      });
    }
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

    return Scaffold(
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: CameraPreview(_controller!),
            ),
            Positioned(
              bottom: 32,
              left: 0,
              right: 0,
              child: FloatingActionButton(
                onPressed: _detections.isNotEmpty ? _captureAndSaveImage : null,
                child: Icon(Icons.camera),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
