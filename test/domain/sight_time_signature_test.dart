// T06 验收：拍号模型（分母缩放拍长、预设、wire、值相等）。
import 'package:test/test.dart';
import 'package:sight_reading/domain/models/sight_time_signature.dart';

void main() {
  group('SightTimeSignature', () {
    test('beatMsAt：4 基准，8 减半', () {
      expect(const SightTimeSignature(4, 4).beatMsAt(60), 1000);
      expect(const SightTimeSignature(4, 8).beatMsAt(60), 500);
      expect(const SightTimeSignature(6, 8).beatMsAt(60), 500);
      expect(const SightTimeSignature(3, 4).beatMsAt(120), 500);
      expect(const SightTimeSignature(2, 4).beatMsAt(50), 1200);
    });

    test('预设列表与 wire/显示名', () {
      expect(
        SightTimeSignature.presets.map((s) => s.wire).toList(),
        ['4/4', '3/4', '2/4', '4/8', '6/8', '3/8'],
      );
      for (final sig in SightTimeSignature.presets) {
        expect(sig.displayName, sig.wire);
        expect(sig.toString(), 'SightTimeSignature(${sig.wire})');
      }
      expect(SightTimeSignature.common4_4,
          const SightTimeSignature(4, 4));
    });

    test('值相等与哈希', () {
      expect(const SightTimeSignature(6, 8),
          const SightTimeSignature(6, 8));
      expect(const SightTimeSignature(6, 8),
          isNot(const SightTimeSignature(3, 4)));
      expect(
        const SightTimeSignature(6, 8).hashCode,
        const SightTimeSignature(6, 8).hashCode,
      );
    });
  });
}
