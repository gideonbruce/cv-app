import 'package:flutter/material.dart';
import 'package:camera/camera.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({Key? key}) : super(key: key);

  @override
  _CameraScreenState createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  CameraController? _controller;
  List<CameraDescription> cameras = [];
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      // Get available cameras
      cameras = await availableCameras();

      // Initialize controller with the first back camera
      final backCamera = cameras.firstWhere(
            (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      _controller = CameraController(
        backCamera,
        // Use high resolution for better detection
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.bgra8888,
      );

      // Initialize the controller
      await _controller!.initialize();

      if (mounted) {
        setState(() {
          _isInitialized = true;
        });

        // Start image stream for real-time processing
        await _controller!.startImageStream((image) {
          // TODO: Add YOLO processing here
          // This is where you'll process each frame for weed detection
        });
      }
    } catch (e) {
      print('Error initializing camera: $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
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
            // Camera preview
            CameraPreview(_controller!),

            // Overlay for bounding boxes
            Positioned.fill(
              child: CustomPaint(
                painter: BoundingBoxPainter(
                  // TODO: Pass detected objects here
                  detectedObjects: [],
                ),
              ),
            ),

            // Controls overlay
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

// Custom painter for drawing bounding boxes
class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detectedObjects; // Replace with your detection model's output type

  BoundingBoxPainter({required this.detectedObjects});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    // TODO: Draw bounding boxes based on detectedObjects
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => true;
}