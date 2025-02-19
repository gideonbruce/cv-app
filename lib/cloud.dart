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

  final cloudinary = CloudinaryPublic('your_cloud_name', 'your_upload_preset', cache: false);

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _loadModel();
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
