import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _shopLogoPathKey = 'shop_logo_path';
final ValueNotifier<int> shopLogoRevision = ValueNotifier<int>(0);

Future<void> saveShopLogo(XFile image) async {
  final extension = image.name.split('.').last.toLowerCase();
  if (!const {'png', 'jpg', 'jpeg', 'webp'}.contains(extension)) {
    throw const FormatException('Choose a PNG, JPG, or WebP logo image.');
  }
  final bytes = await image.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  frame.image.dispose();
  codec.dispose();

  final supportDirectory = await getApplicationSupportDirectory();
  final logoFile = File(
    '${supportDirectory.path}${Platform.pathSeparator}shop_logo.$extension',
  );
  await logoFile.writeAsBytes(bytes, flush: true);
  await SharedPreferencesAsync().setString(_shopLogoPathKey, logoFile.path);
  shopLogoRevision.value++;
}

Future<void> resetShopLogo() async {
  final preferences = SharedPreferencesAsync();
  final path = await preferences.getString(_shopLogoPathKey);
  await preferences.remove(_shopLogoPathKey);
  if (path != null) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
  shopLogoRevision.value++;
}

Future<String?> _savedShopLogoPath() async {
  try {
    return await SharedPreferencesAsync().getString(_shopLogoPathKey);
  } on StateError {
    return null;
  }
}

Future<Uint8List> loadShopLogoBytes(String fallbackAsset) async {
  final path = await _savedShopLogoPath();
  if (path != null) {
    final file = File(path);
    if (await file.exists()) return file.readAsBytes();
  }
  final data = await rootBundle.load(fallbackAsset);
  return data.buffer.asUint8List();
}

Widget shopLogoImage({
  required String fallbackAsset,
  required double width,
  required double height,
  BoxFit fit = BoxFit.contain,
}) {
  return ValueListenableBuilder<int>(
    valueListenable: shopLogoRevision,
    builder: (context, _, _) => FutureBuilder<String?>(
      future: _savedShopLogoPath(),
      builder: (context, snapshot) {
        final path = snapshot.data;
        if (path != null) {
          return Image.file(
            File(path),
            width: width,
            height: height,
            fit: fit,
            errorBuilder: (_, _, _) => Image.asset(
              fallbackAsset,
              width: width,
              height: height,
              fit: fit,
            ),
          );
        }
        return Image.asset(
          fallbackAsset,
          width: width,
          height: height,
          fit: fit,
        );
      },
    ),
  );
}
