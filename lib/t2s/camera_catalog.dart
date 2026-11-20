// Known cameras and the automatic choice of protocol and video mode.

import 't2s_frame.dart';
import 'temperature_model.dart';

/// A camera model recognised by its USB vendor:product ID.
class KnownCamera {
  const KnownCamera(
    this.usbId,
    this.name,
    this.family, {
    this.revision,
    this.vendorBulkStream,
  });

  /// `vvvv:pppp` in lower-case hex.
  final String usbId;
  final String name;
  final CameraFamily family;

  /// Xtherm hardware revision when known from the ID; null means it is
  /// detected from the picture.
  final HardwareRevision? revision;

  /// Stream size (width, 2·image height + 2) of a camera that streams over
  /// a vendor bulk pipe the UVC stack does not enumerate; connecting starts
  /// that stream directly. Null for ordinary UVC cameras.
  final (int, int)? vendorBulkStream;
}

/// Frame format that makes the camera plugin start a vendor bulk stream
/// (see [KnownCamera.vendorBulkStream]). Mirrors
/// UVC_FRAME_FORMAT_VENDOR_BULK in the plugin's C header.
const int kVendorBulkFrameFormat = 100;

const List<KnownCamera> kKnownCameras = <KnownCamera>[
  KnownCamera(
    '04b4:0100',
    'InfiRay T2S+ V2',
    CameraFamily.xtherm,
    revision: HardwareRevision.v2,
  ),
  KnownCamera(
    '1514:0001',
    'InfiRay T2S+ V2',
    CameraFamily.xtherm,
    revision: HardwareRevision.v2,
  ),
  KnownCamera(
    '3474:6002',
    'Xtherm II T2S+',
    CameraFamily.xtherm,
    revision: HardwareRevision.v2,
  ),
  // Realtek bridge used by InfiRay's Tiny1-C modules.
  KnownCamera('0bda:5830', 'InfiRay P2 Pro / Topdon TC001', CameraFamily.tiny1c),
  KnownCamera(
    '3474:45a2',
    'ThermalMaster P3',
    CameraFamily.p3,
    vendorBulkStream: (256, 386),
  ),
  KnownCamera(
    '3474:45c2',
    'ThermalMaster P1',
    CameraFamily.p3,
    vendorBulkStream: (160, 242),
  ),
];

KnownCamera? knownCamera(String usbId) {
  for (final KnownCamera c in kKnownCameras) {
    if (c.usbId == usbId) return c;
  }
  return null;
}

/// A video mode as offered by the camera (format name, size).
class OfferedMode {
  const OfferedMode(this.formatName, this.width, this.height, this.index);

  final String formatName;
  final int width;
  final int height;

  /// Position in the camera's mode list.
  final int index;

  bool get uncompressed {
    final String f = formatName.toUpperCase();
    return f != 'MJPEG' && f != 'H264';
  }
}

/// Result of [chooseStream].
class StreamChoice {
  const StreamChoice(this.family, this.modeIndex, this.reason);

  final CameraFamily family;
  final int modeIndex;
  final String reason;
}

/// Image sizes of the Xtherm line; the stream adds 4 metadata rows.
const List<(int, int)> _xthermImages = <(int, int)>[
  (256, 192),
  (384, 288),
  (640, 512),
  (240, 180),
];

/// Image sizes of Tiny1-C style modules; the stream is twice as high.
const List<(int, int)> _tiny1cImages = <(int, int)>[
  (256, 192),
  (160, 120),
  (384, 288),
];

/// Image sizes of ThermalMaster P3/P1 cameras: picture, two info rows and
/// temperatures in one double-height stream (2h+2 rows).
const List<(int, int)> _p3Images = <(int, int)>[
  (256, 192),
  (160, 120),
];

/// Picks protocol and video mode: a known USB ID decides the family, and
/// the characteristic stream sizes decide otherwise.
StreamChoice? chooseStream(List<OfferedMode> modes, KnownCamera? known) {
  final List<OfferedMode> raw = modes.where((OfferedMode m) => m.uncompressed).toList();
  OfferedMode? find(int w, int h) {
    for (final OfferedMode m in raw) {
      if (m.width == w && m.height == h) return m;
    }
    return null;
  }

  StreamChoice? xtherm(String why) {
    for (final (int w, int h) in _xthermImages) {
      final OfferedMode? m = find(w, h + 4);
      if (m != null) {
        return StreamChoice(CameraFamily.xtherm, m.index, '$why, ${w}x${h + 4} stream');
      }
    }
    return null;
  }

  StreamChoice? tiny1c(String why) {
    for (final (int w, int h) in _tiny1cImages) {
      final OfferedMode? m = find(w, h * 2);
      if (m != null) {
        return StreamChoice(CameraFamily.tiny1c, m.index, '$why, ${w}x${h * 2} stream');
      }
    }
    return null;
  }

  StreamChoice? p3(String why) {
    for (final (int w, int h) in _p3Images) {
      final OfferedMode? m = find(w, h * 2 + 2);
      if (m != null) {
        return StreamChoice(CameraFamily.p3, m.index, '$why, ${w}x${h * 2 + 2} stream');
      }
    }
    return null;
  }

  if (known != null) {
    final String why = 'known camera ${known.name}';
    final StreamChoice? c = switch (known.family) {
      CameraFamily.xtherm => xtherm(why),
      CameraFamily.tiny1c => tiny1c(why),
      CameraFamily.p3 => p3(why),
    };
    if (c != null) return c;
  }
  return xtherm('stream with 4 metadata rows') ??
      p3('stream of two halves plus info rows') ??
      tiny1c('stream of two equal halves');
}
