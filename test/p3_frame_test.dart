import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/t2s/t2s_frame.dart';
import 'package:t2s_thermal/t2s/temperature_model.dart';

/// A ThermalMaster P3 style frame: w×h YUYV-like picture rows, 2 info
/// rows, then w×h temperatures in 1/64 K.
Uint8List p3Frame(int w, int h, double Function(int x, int y) celsius) {
  final ByteData d = ByteData(w * (2 * h + 2) * 2);
  for (int i = 0; i < w * h; i++) {
    d.setUint8(i * 2, (i * 37) & 0xFF); // Y-ish noise
    d.setUint8(i * 2 + 1, 128); // U/V-ish filler
  }
  final int infoBase = w * h * 2;
  final int thermalBase = infoBase + w * 4;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int raw = ((celsius(x, y) + 273.15) * 64).round();
      d.setUint16(thermalBase + (y * w + x) * 2, raw, Endian.little);
    }
  }
  return d.buffer.asUint8List();
}

void main() {
  group('P3 frames', () {
    test(
      'thermal plane below the picture and info rows becomes temperatures',
      () {
        final T2sFrame f = T2sFrame.decodeP3(
          p3Frame(256, 192, (int x, int y) => 20 + x / 10 + y / 100),
          256,
          386,
        )!;
        expect(f.family, CameraFamily.p3);
        expect(f.width, 256);
        expect(f.height, 192);
        expect(f.meta, isNull);
        expect(f.profile, isNull);
        final TemperatureTable t = TemperatureTable.linear(
          const ModelSettings(revision: HardwareRevision.v1),
        );
        double at(int x, int y) => t.lookup(f.counts[y * 256 + x]);
        expect(at(0, 0), closeTo(20.0, 0.05));
        expect(at(255, 0), closeTo(45.5, 0.05));
        expect(at(100, 150), closeTo(31.5, 0.05));
      },
    );

    test('covers both gain ranges', () {
      final T2sFrame f = T2sFrame.decodeP3(
        p3Frame(256, 192, (int x, int y) => x < 128 ? -20 : 550),
        256,
        386,
      )!;
      final TemperatureTable t = TemperatureTable.linear(
        const ModelSettings(revision: HardwareRevision.v1),
      );
      expect(t.lookup(f.counts[0]), closeTo(-20, 0.05));
      expect(t.lookup(f.counts[200]), closeTo(550, 0.05));
    });

    test('P1 shape 160x242 decodes', () {
      final T2sFrame f = T2sFrame.decodeP3(
        p3Frame(160, 120, (int x, int y) => 25),
        160,
        242,
      )!;
      expect(f.family, CameraFamily.p3);
      expect(f.width, 160);
      expect(f.height, 120);
      expect(f.counts, everyElement(f.counts.first));
    });

    test('rejects short payloads', () {
      expect(T2sFrame.decodeP3(Uint8List(197631), 256, 386), isNull);
    });

    test('decodes the first frame of a longer payload', () {
      final Uint8List frame = p3Frame(256, 192, (int x, int y) => 30);
      final Uint8List longer = Uint8List(frame.length + 64)..setAll(0, frame);
      final T2sFrame f = T2sFrame.decodeP3(longer, 256, 386)!;
      expect(f.rawBytes.length, frame.length);
      expect(
        f.counts,
        everyElement(T2sFrame.decodeP3(frame, 256, 386)!.counts.first),
      );
    });

    test('rejects odd stream heights', () {
      expect(
        T2sFrame.decodeP3(p3Frame(256, 192, (int x, int y) => 20), 256, 385),
        isNull,
      );
    });

    test('raw bytes are preserved for export', () {
      final Uint8List frame = p3Frame(256, 192, (int x, int y) => 20);
      expect(T2sFrame.decodeP3(frame, 256, 386)!.rawBytes.length, frame.length);
    });
  });
}
