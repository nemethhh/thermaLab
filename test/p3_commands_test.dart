import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:t2s_thermal/t2s/p3_commands.dart';

/// Records one control transfer and hands scripted replies to IN requests.
class _FakeTransfer {
  _FakeTransfer([List<int>? inReplies])
    : replies = Queue<Uint8List>.from([
        for (final int r in inReplies ?? const <int>[]) Uint8List.fromList([r]),
      ]);

  final Queue<Uint8List> replies;
  final List<Map<String, Object?>> calls = <Map<String, Object?>>[];

  Uint8List call({
    required int requestType,
    required int request,
    required int value,
    required int index,
    Uint8List? data,
    int length = 0,
    int timeoutMs = 1000,
  }) {
    calls.add(<String, Object?>{
      'requestType': requestType,
      'request': request,
      'value': value,
      'index': index,
      'data': data == null ? null : _hex(data),
      'length': length,
    });
    if ((requestType & 0x80) != 0) {
      if (replies.isEmpty) {
        throw StateError(
          'unexpected IN request 0x${request.toRadixString(16)}',
        );
      }
      return replies.removeFirst();
    }
    return Uint8List(0);
  }

  /// The data payload of the n-th OUT (0x41/0x20) command, as hex.
  String commandHex(int n) => calls[n]['data']! as String;
}

String _hex(Uint8List bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

P3Commands _commands(_FakeTransfer t, {int maxStatusPolls = 2000}) =>
    P3Commands(t.call, maxStatusPolls: maxStatusPolls, pollDelay: () async {});

void main() {
  group('frame builder goldens (from P3 USB captures)', () {
    test('register reads', () {
      expect(
        _hex(
          buildP3Frame(
            cmd: 0x0101,
            param: 0x81,
            payloadByte4: 0x01,
            readLength: 30,
          ),
        ),
        '0101810001000000000000001e0000004f90',
      );
      expect(
        _hex(
          buildP3Frame(
            cmd: 0x0101,
            param: 0x81,
            payloadByte4: 0x02,
            readLength: 12,
          ),
        ),
        '0101810002000000000000000c0000001f63',
      );
      expect(
        _hex(
          buildP3Frame(
            cmd: 0x0101,
            param: 0x81,
            payloadByte4: 0x06,
            readLength: 64,
          ),
        ),
        '01018100060000000000000040000000654f',
      );
      expect(
        _hex(
          buildP3Frame(
            cmd: 0x0101,
            param: 0x81,
            payloadByte4: 0x07,
            readLength: 64,
          ),
        ),
        '01018100070000000000000040000000104c',
      );
    });

    test('gain set low/high and manual FFC', () {
      expect(
        _hex(buildP3Frame(cmd: 0x2F01, param: 0x41, payloadByte4: 0)),
        '012f41000000000000000000000000003c3a',
      );
      expect(
        _hex(buildP3Frame(cmd: 0x2F01, param: 0x41, payloadByte4: 1)),
        '012f41000100000000000000000000004939',
      );
      expect(
        _hex(buildP3Frame(cmd: 0x3601, param: 0x43, payloadByte4: 0)),
        '01364300000000000000000000000000cd0b',
      );
    });

    test('gain read frame asks for one byte (capture "start_stream")', () {
      expect(
        _hex(buildP3Frame(cmd: 0x2F01, param: 0x81, readLength: 1)),
        '012f81000000000000000000010000004930',
      );
    });
  });

  group('write commands', () {
    test(
      'setHighGain(true) sends the capture-verified high-gain frame',
      () async {
        final _FakeTransfer t = _FakeTransfer(<int>[0x02]);
        await _commands(t).setHighGain(true);
        expect(t.calls[0]['requestType'], 0x41);
        expect(t.calls[0]['request'], 0x20);
        expect(t.calls[0]['index'], 0);
        expect(t.commandHex(0), '012f41000100000000000000000000004939');
        expect(t.calls[1]['request'], 0x22); // status poll
      },
    );

    test('setHighGain(false) sends the low-gain frame', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x02]);
      await _commands(t).setHighGain(false);
      expect(t.commandHex(0), '012f41000000000000000000000000003c3a');
    });

    test('triggerShutter sends the manual FFC frame', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x02]);
      await _commands(t).triggerShutter();
      expect(t.commandHex(0), '01364300000000000000000000000000cd0b');
    });
  });

  group('serialisation', () {
    test('a command waits until the previous exchange is done', () async {
      // Reads: done, data, read-done; then the write: done.
      final _FakeTransfer t = _FakeTransfer(<int>[
        0x01,
        0x02,
        0x31,
        0x03,
        0x02,
      ]);
      final P3Commands c = _commands(t);
      final Future<bool> gain = c.readHighGain();
      final Future<void> shutter = c.triggerShutter();
      expect(await gain, isTrue);
      await shutter;
      final List<int> requests = <int>[
        for (final Map<String, Object?> call in t.calls)
          call['request']! as int,
      ];
      expect(requests, <int>[0x20, 0x22, 0x22, 0x21, 0x22, 0x20, 0x22]);
      expect(t.commandHex(5), '01364300000000000000000000000000cd0b');
    });

    test('a failed command does not block the next one', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x7F, 0x02]);
      final P3Commands c = _commands(t);
      await expectLater(c.setHighGain(true), throwsStateError);
      await c.triggerShutter();
      expect(t.commandHex(2), '01364300000000000000000000000000cd0b');
    });
  });

  group('read commands', () {
    test('readHighGain maps nonzero reply bytes to high gain', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x02, 0x31, 0x03]);
      expect(await _commands(t).readHighGain(), isTrue);

      final _FakeTransfer zero = _FakeTransfer(<int>[0x02, 0x00, 0x03]);
      expect(await _commands(zero).readHighGain(), isFalse);
    });

    test('readHighGain reads one byte via 0x21 then final status', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x02, 0x01, 0x03]);
      await _commands(t).readHighGain();
      expect(t.calls[2]['requestType'], 0xC1);
      expect(t.calls[2]['request'], 0x21);
      expect(t.calls[2]['length'], 1);
      expect(t.calls[3]['request'], 0x22);
    });

    test('readRegisterString stops at the first NUL', () async {
      final Uint8List reply = Uint8List(30);
      reply[0] = 0x50; // P
      reply[1] = 0x33; // 3
      final _FakeTransfer t = _FakeTransfer(<int>[]);
      t.replies.add(Uint8List.fromList(<int>[0x02]));
      t.replies.add(reply);
      t.replies.add(Uint8List.fromList(<int>[0x03]));
      expect(await _commands(t).readRegisterString(P3Register.model, 30), 'P3');
    });

    test('busy status times out without reading data', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[
        0x01,
        0x01,
        0x01,
        0x01,
        0x01,
      ]);
      await expectLater(
        _commands(t, maxStatusPolls: 5).readHighGain(),
        throwsStateError,
      );
      final int statusPolls = t.calls
          .where((Map<String, Object?> c) => c['request'] == 0x22)
          .length;
      expect(statusPolls, 5);
      expect(
        t.calls.where((Map<String, Object?> c) => c['request'] == 0x21),
        isEmpty,
      );
    });

    test('an unexpected status byte is reported, not retried', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[0x7F]);
      await expectLater(
        _commands(t, maxStatusPolls: 50).readHighGain(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('0x7f'),
          ),
        ),
      );
    });

    test('a zero-length status reply is reported as a camera error', () async {
      final _FakeTransfer t = _FakeTransfer(<int>[]);
      t.replies.add(Uint8List(0));
      await expectLater(
        _commands(t).readHighGain(),
        throwsA(
          isA<StateError>().having(
            (StateError e) => e.message,
            'message',
            contains('status'),
          ),
        ),
      );
    });
  });
}
