import 'dart:developer' show log;
import 'dart:math' hide log;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_screen_capture/src/captured_screen_area.dart';
import 'package:image/image.dart' as image_lib;
import 'package:screen_retriever/screen_retriever.dart';

class ScreenCapture {
  final _methodChannel = const MethodChannel('flutter_screen_capture');

  /// Captures the entire screen area of a given display.
  /// If [displayId] is null, defaults to primary (id == '1') or first available.
  Future<CapturedScreenArea?> captureEntireScreen({String? displayId}) async {
    final allDisplays = await ScreenRetriever.instance.getAllDisplays();
    if (allDisplays.isEmpty) return null;

    final targetDisplay = displayId == null
        ? allDisplays.firstWhere((d) => d.id == '1',
            orElse: () => allDisplays.first)
        : allDisplays.firstWhere((d) => d.id == displayId,
            orElse: () => allDisplays.first);

    final pos = targetDisplay.visiblePosition ?? Offset.zero;
    final size = targetDisplay.visibleSize ?? targetDisplay.size;

    log('captureEntireScreen: '
        'targetDisplay=${targetDisplay.id}, pos=$pos, size=$size');

    return captureScreenArea(
      Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
      targetDisplay: targetDisplay,
    );
  }

  /// Capture an image from every connected display, then combine these images
  /// into a single, horizontally stitched image and return the final image data.
  Future<CapturedScreenArea?> captureAllDisplaysCombined() async {
    final allDisplays = await ScreenRetriever.instance.getAllDisplays();
    if (allDisplays.isEmpty) return null;

    final List<CapturedScreenArea> capturedAreas = [];
    for (final display in allDisplays) {
      final area = await captureEntireScreen(displayId: display.id);
      if (area != null) {
        capturedAreas.add(area);
      }
    }

    if (capturedAreas.isEmpty) return null;

    final images = capturedAreas.map((e) => e.toImage()).toList();
    final totalWidth = images.fold<int>(0, (prev, img) => prev + img.width);
    final maxHeight = images.fold<int>(0, (prev, img) => max(prev, img.height));

    final compositeImage = image_lib.Image(
      width: totalWidth,
      height: maxHeight,
    );

    var currentX = 0;
    for (final img in images) {
      image_lib.compositeImage(
        compositeImage,
        img,
        dstX: currentX,
        dstY: (maxHeight - img.height) ~/ 2, // Vertically center
      );
      currentX += img.width;
    }

    final firstArea = capturedAreas.first;

    return CapturedScreenArea(
      buffer: compositeImage.getBytes(order: firstArea.channelOrder),
      width: totalWidth,
      height: maxHeight,
      bitsPerPixel: firstArea.bitsPerPixel,
      bytesPerPixel: firstArea.bytesPerPixel,
    );
  }

  /// Captures a screen area.
  /// Pass [targetDisplay] when you want the rect validated against a specific display
  /// (prevents sanitization to primary only).
  Future<CapturedScreenArea?> captureScreenArea(
      Rect rect, {
        Display? targetDisplay,
      }) async {
    if (rect.isEmpty) return null;

    final correctedRect = await _sanitizeRect(rect,);
    if (correctedRect.isEmpty) return null;

    // Logging to help debug whether we are sending correct coords to native
    log('-> captureScreenArea: requested=$rect corrected=$correctedRect');

    final result = await _methodChannel.invokeMethod<Map<Object?, Object?>>(
      'captureScreenArea',
      <String, dynamic>{
        'x': correctedRect.left.toInt(),
        'y': correctedRect.top.toInt(),
        'width': correctedRect.width.toInt(),
        'height': correctedRect.height.toInt(),
      },
    );
    if (result == null) return null;

    final area = CapturedScreenArea.fromJson(result);
    return _sanitizeCapturedArea(area, rect, correctedRect);
  }

  /// Captures the color of a pixel on the screen.
  Future<Color?> captureScreenColor(double x, double y) async {
    final area = await captureScreenArea(
      Rect.fromLTWH(x, y, 1, 1),
    );
    return area?.getPixelColor(0, 0);
  }
}

/// If [targetDisplay] is provided, sanitize/intersect against that display's visible rect.
/// Otherwise fall back to primary display as before.
Future<Rect> _sanitizeRect(Rect rect) async {
  final allDisplays = await ScreenRetriever.instance.getAllDisplays();

  // Find which display this rect belongs to
  for (final display in allDisplays) {
    final displayRect = Rect.fromLTWH(
      display.visiblePosition?.dx ?? 0,
      display.visiblePosition?.dy ?? 0,
      display.size.width,
      display.size.height,
    );
    if (displayRect.overlaps(rect)) {
      // Clip only within this display
      return rect.intersect(displayRect);
    }
  }

  // fallback: return rect unchanged
  return rect;
}


Future<CapturedScreenArea> _sanitizeCapturedArea(
    CapturedScreenArea area,
    Rect originalRect,
    Rect correctedRect,
    ) async {
  var correctedArea = area;

  if (correctedRect != originalRect) {
    final originalWidth = originalRect.width.toInt();
    final originalHeight = originalRect.height.toInt();

    final emptyImage = image_lib.Image.fromBytes(
      width: originalWidth,
      height: originalHeight,
      bytes: Uint8List.fromList(List<int>.filled(originalWidth * originalHeight * 4, 0)).buffer,
    );

    final correctedImage = image_lib.compositeImage(
      emptyImage,
      area.toImage(),
      dstX: (correctedRect.left - originalRect.left).toInt(),
      dstY: (correctedRect.top - originalRect.top).toInt(),
      blend: image_lib.BlendMode.direct,
    );

    correctedArea = correctedArea.copyWith(
      buffer: correctedImage.getBytes(
        order: correctedArea.channelOrder,
      ),
      width: originalWidth,
      height: originalHeight,
    );
  }

  return correctedArea;
}
