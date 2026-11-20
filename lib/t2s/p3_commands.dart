// Vendor commands for ThermalMaster P3 / P1 thermal cameras (USB
// 3474:45a2 / 3474:45c2).
//
// Frames and handshake from the USB captures in
// https://github.com/jvdillon/p3-ir-camera (Apache-2.0): an 18-byte command
// frame goes out as vendor control transfer 0x41/0x20, the status register
// (0xC1/0x22) is polled while the camera reports busy, and read responses
// come from 0xC1/0x21.

import 'dart:async';
import 'dart:typed_data';

import 'tiny1c_commands.dart' show ControlTransfer;

/// Command words, little-endian on the wire.
abstract final class P3Cmd {
  /// Device information registers (register id in payload byte 4).
  static const int deviceInfo = 0x0101;

  /// Gain mode read/write: low (0) or high (1).
  static const int gain = 0x2F01;

  /// Manual flat-field correction (shutter click).
  static const int manualFfc = 0x3601;
}

/// Parameter byte in the frame header.
abstract final class P3Param {
  /// Read; payload byte 4 selects the register.
  static const int read = 0x81;

  /// Write; payload byte 4 carries the value.
  static const int write = 0x41;

  /// Manual FFC update.
  static const int ffcUpdate = 0x43;
}

/// Device information registers of [P3Cmd.deviceInfo].
abstract final class P3Register {
  static const int model = 0x01;
  static const int firmware = 0x02;
  static const int serial = 0x07;
}

/// Status register values (one byte via request 0x22).
abstract final class P3Status {
  static const int busy = 0x01;

  /// Write done, or response data ready.
  static const int done = 0x02;

  /// Response data has been read out.
  static const int readDone = 0x03;
}

/// CRC-16/CCITT (poly 0x1021, init 0, no reflection, no final xor). The
/// camera ignores it, but the vendor library always sends it.
int p3Crc16(Uint8List bytes) {
  int crc = 0;
  for (final int byte in bytes) {
    crc ^= byte << 8;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
      crc &= 0xFFFF;
    }
  }
  return crc;
}

/// One 18-byte command frame: u16 command, parameter byte, payload byte 4,
/// u16 response length at 12 for reads, CRC16 of bytes 0..15 at 16.
Uint8List buildP3Frame({
  required int cmd,
  required int param,
  int payloadByte4 = 0,
  int readLength = 0,
}) {
  final ByteData d = ByteData(18)
    ..setUint16(0, cmd, Endian.little)
    ..setUint8(2, param)
    ..setUint8(4, payloadByte4)
    ..setUint16(12, readLength, Endian.little);
  d.setUint16(16, p3Crc16(d.buffer.asUint8List(0, 16)), Endian.little);
  return d.buffer.asUint8List();
}

class P3Commands {
  P3Commands(
    this.transfer, {
    this.maxStatusPolls = 2000,
    this.pollDelay = _delayOneMs,
  });

  final ControlTransfer transfer;

  /// Status polls before giving up; the vendor library polls 2000 times
  /// with 1 ms pauses.
  final int maxStatusPolls;
  final Future<void> Function() pollDelay;

  // Each command is a multi-transfer exchange with a single status
  // register, so commands must not interleave.
  Future<void> _last = Future<void>.value();

  static Future<void> _delayOneMs() =>
      Future<void>.delayed(const Duration(milliseconds: 1));

  /// Reads a device information register as text, cut at the first NUL.
  Future<String> readRegisterString(int register, int length) async {
    final Uint8List raw = await _read(
      buildP3Frame(
        cmd: P3Cmd.deviceInfo,
        param: P3Param.read,
        payloadByte4: register,
        readLength: length,
      ),
      length,
    );
    final int end = raw.indexOf(0);
    return String.fromCharCodes(end < 0 ? raw : raw.sublist(0, end)).trim();
  }

  /// Current gain: 0 is low gain, anything else (captures show 0x31 and
  /// 0x35) high gain.
  Future<bool> readHighGain() async {
    final Uint8List raw = await _read(
      buildP3Frame(cmd: P3Cmd.gain, param: P3Param.read, readLength: 1),
      1,
    );
    return raw.isNotEmpty && raw[0] != 0;
  }

  /// High gain = normal range (about -20..150 °C), low gain = high range
  /// (about 0..550 °C). The camera keeps the setting across power cycles.
  Future<void> setHighGain(bool high) => _write(
    buildP3Frame(
      cmd: P3Cmd.gain,
      param: P3Param.write,
      payloadByte4: high ? 1 : 0,
    ),
  );

  /// Runs a manual flat-field correction; the shutter clicks.
  Future<void> triggerShutter() =>
      _write(buildP3Frame(cmd: P3Cmd.manualFfc, param: P3Param.ffcUpdate));

  Future<T> _serialized<T>(Future<T> Function() exchange) {
    final Future<T> result = _last.then((_) => exchange());
    _last = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> _write(Uint8List frame) => _serialized(() async {
    _send(frame);
    await _waitStatus(P3Status.done);
  });

  Future<Uint8List> _read(Uint8List frame, int length) => _serialized(() async {
    _send(frame);
    await _waitStatus(P3Status.done);
    final Uint8List data = transfer(
      requestType: 0xC1,
      request: 0x21,
      value: 0,
      index: 0,
      length: length,
    );
    await _waitStatus(P3Status.readDone);
    return data;
  });

  void _send(Uint8List frame) {
    transfer(requestType: 0x41, request: 0x20, value: 0, index: 0, data: frame);
  }

  Future<void> _waitStatus(int expected) async {
    for (int i = 0; i < maxStatusPolls; i++) {
      final Uint8List reply = transfer(
        requestType: 0xC1,
        request: 0x22,
        value: 0,
        index: 0,
        length: 1,
      );
      if (reply.isEmpty) throw StateError('camera status reply was empty');
      final int status = reply.first;
      if (status == expected) return;
      if (status != P3Status.busy) {
        throw StateError('camera status 0x${status.toRadixString(16)}');
      }
      await pollDelay();
    }
    throw StateError('camera stayed busy for $maxStatusPolls polls');
  }
}
