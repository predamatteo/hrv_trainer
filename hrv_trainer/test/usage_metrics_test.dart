import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/usage/usage_metrics.dart';

void main() {
  DateTime day(int y, int m, int d) => DateTime(y, m, d);

  group('UsageMetrics.summarize', () {
    test('vuoto → tutto zero/null', () {
      final s = UsageMetrics.empty.summarize(day(2026, 6, 10));
      expect(s.activeDays, 0);
      expect(s.currentStreak, 0);
      expect(s.returnedD1, isFalse);
      expect(s.returnedD7, isFalse);
      expect(s.timeToFirstBreath, isNull);
      expect(s.onboardingCompleted, isFalse);
    });

    test('streak consecutiva terminando oggi', () {
      final m = UsageMetrics(
        openDays: [day(2026, 6, 8), day(2026, 6, 9), day(2026, 6, 10)],
      );
      expect(m.summarize(day(2026, 6, 10)).currentStreak, 3);
    });

    test('streak ancorata a ieri se non aperto oggi', () {
      final m = UsageMetrics(openDays: [day(2026, 6, 8), day(2026, 6, 9)]);
      expect(m.summarize(day(2026, 6, 10)).currentStreak, 2);
    });

    test('streak interrotta se ultimo open più vecchio di ieri', () {
      final m = UsageMetrics(openDays: [day(2026, 6, 7), day(2026, 6, 8)]);
      expect(m.summarize(day(2026, 6, 10)).currentStreak, 0);
    });

    test('returnedD1 e returnedD7', () {
      final first = DateTime(2026, 6, 1, 9);
      final d1 = UsageMetrics(
        firstOpenAt: first,
        openDays: [day(2026, 6, 1), day(2026, 6, 2)],
      );
      expect(d1.summarize(day(2026, 6, 2)).returnedD1, isTrue);
      expect(d1.summarize(day(2026, 6, 2)).returnedD7, isTrue);

      final d7 = UsageMetrics(
        firstOpenAt: first,
        openDays: [day(2026, 6, 1), day(2026, 6, 5)],
      );
      expect(d7.summarize(day(2026, 6, 5)).returnedD1, isFalse);
      expect(d7.summarize(day(2026, 6, 5)).returnedD7, isTrue);

      final none = UsageMetrics(
        firstOpenAt: first,
        openDays: [day(2026, 6, 1), day(2026, 6, 20)],
      );
      expect(none.summarize(day(2026, 6, 20)).returnedD7, isFalse);
    });

    test('timeToFirstBreath = primo respiro − primo avvio', () {
      final m = UsageMetrics(
        firstOpenAt: DateTime(2026, 6, 1, 9, 0),
        firstBreathAt: DateTime(2026, 6, 1, 9, 0, 40),
      );
      expect(
        m.summarize(day(2026, 6, 1)).timeToFirstBreath,
        const Duration(seconds: 40),
      );
    });
  });

  test('json roundtrip preserva i campi', () {
    final m = UsageMetrics(
      firstOpenAt: DateTime(2026, 6, 1, 9),
      onboardingDoneAt: DateTime(2026, 6, 1, 9, 1),
      firstBreathAt: DateTime(2026, 6, 1, 9, 2),
      openDays: [day(2026, 6, 1), day(2026, 6, 2)],
    );
    final back = UsageMetrics.fromJson(m.toJson());
    expect(back.firstOpenAt, m.firstOpenAt);
    expect(back.onboardingDoneAt, m.onboardingDoneAt);
    expect(back.firstBreathAt, m.firstBreathAt);
    expect(back.openDays, m.openDays);
  });
}
