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

    final Display targetDisplay = displayId == null
        ? allDisplays.firstWhere((d) => d.id == '1', orElse: () => allDisplays.first)
        : allDisplays.firstWhere((d) => d.id == displayId, orElse: () => allDisplays.first);

    final pos = targetDisplay.visiblePosition ?? Offset.zero;
    final size = targetDisplay.visibleSize ?? targetDisplay.size;

    log('captureEntireScreen: targetDisplay=${targetDisplay.id}, pos=$pos, size=$size');

    return captureScreenArea(
      Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
      targetDisplay: targetDisplay,
    );
  }

  /// Capture and return a single CapturedScreenArea for each display and combine
  /// them into one image covering the whole virtual screen (useful if you want all monitors).
  Future<CapturedScreenArea?> captureAllDisplaysCombined() async {
    final allDisplays = await ScreenRetriever.instance.getAllDisplays();
    if (allDisplays.isEmpty) return null;

    // Build list of display rects in global coordinates
    final displayRects = allDisplays.map((d) {
      final pos = d.visiblePosition ?? Offset.zero;
      final size = d.visibleSize ?? d.size;
      return Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);
    }).toList();

    // Compute bounding box of all displays
    final minX = displayRects.map((r) => r.left).reduce(min);
    final minY = displayRects.map((r) => r.top).reduce(min);
    final maxX = displayRects.map((r) => r.right).reduce(max);
    final maxY = displayRects.map((r) => r.bottom).reduce(max);
    final totalWidth = (maxX - minX).toInt();
    final totalHeight = (maxY - minY).toInt();

    // Create empty RGBA image (black background)
    final combinedImage = image_lib.Image.fromBytes(
      width: totalWidth,
      height: totalHeight,
      bytes: Uint8List.fromList(List<int>.filled(totalWidth * totalHeight * 4, 0)).buffer,
    );

    // Capture each display and composite it in the right position
    for (int i = 0; i < allDisplays.length; i++) {
      final d = allDisplays[i];
      final rect = displayRects[i];
      log('Capturing display ${d.id} rect=$rect');

      final area = await captureScreenArea(rect, targetDisplay: d);
      if (area == null) {
        log('captureAllDisplaysCombined: display ${d.id} returned null area');
        continue;
      }

      final dstX = (rect.left - minX).toInt();
      final dstY = (rect.top - minY).toInt();

      image_lib.compositeImage(
        combinedImage,
        area.toImage(),
        dstX: dstX,
        dstY: dstY,
        blend: image_lib.BlendMode.direct,
      );
    }

    return CapturedScreenArea(
      buffer: combinedImage.getBytes(
        // order: ChannelOrder.rgba, // adjust if your plugin uses different order
      ),
      bitsPerPixel: 32,
      bytesPerPixel: 4,
      width: totalWidth,
      height: totalHeight,
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

    final correctedRect = await _sanitizeRect(rect, targetDisplay: targetDisplay);
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
Future<Rect> _sanitizeRect(Rect rect, {Display? targetDisplay}) async {
  final allDisplays = await ScreenRetriever.instance.getAllDisplays();

  Display display;
  if (targetDisplay != null) {
    display = targetDisplay;
  } else {
    display = allDisplays.firstWhere((d) => d.id == '1', orElse: () => allDisplays.first);
  }

  final pos = display.visiblePosition ?? Offset.zero;
  final size = display.visibleSize ?? display.size;
  final displayRect = Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height);

  // If rect is completely outside the display, intersection will be empty.
  return rect.intersect(displayRect);
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
