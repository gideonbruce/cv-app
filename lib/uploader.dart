import 'dart:io';
import 'package:http/http.dart' as http;
import 'dart:convert';

class CloudinaryService {
  static const String cloudName = "daq0tdpcm";
  static const String apiKey = "856251836494621";
  static const String apiSecret = "-GnDyhLxduB99DUChiR8z207ZCQ";

  static Future<String?> uploadImage(File imageFile) async {
    final url = "https://api.cloudinary.com/v1_1/$daq0tdpcm/image/upload";

    final request = http.MultipartRequest('POST', Uri.parse(url))
      ..fields['upload_preset'] = "your_upload_preset"
      ..fields['api_key'] = apiKey
      ..files.add(await http.MultipartFile.fromPath('file', imageFile.path));

    final response = await request.send();
    final responseData = await response.stream.bytesToString();

    if (response.statusCode == 200) {
      final jsonResponse = jsonDecode(responseData);
      return jsonResponse['secure_url']; // Cloudinary image URL
    } else {
      print("Upload failed: ${responseData}");
      return null;
    }
  }
}
