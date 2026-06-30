import 'package:flutter_test/flutter_test.dart';
import 'package:hrv_trainer/shared/training_plan/plan_providers.dart';

void main() {
  group('AssessmentGate', () {
    test('nessun assessment → blocca, niente RF', () {
      expect(AssessmentGate.none.hasAssessment, isFalse);
      expect(AssessmentGate.none.canStartPlan, isFalse);
      expect(AssessmentGate.none.recommendReassess, isFalse);
    });

    test('assessment senza RF valida → blocca l\'avvio', () {
      final g = AssessmentGate(takenAt: DateTime(2026, 6, 1), ageDays: 1);
      expect(g.hasAssessment, isTrue);
      expect(g.hasUsableRf, isFalse);
      expect(g.canStartPlan, isFalse);
    });

    test('RF recente → avvio consentito, niente invito a rifare', () {
      final g =
          AssessmentGate(bpm: 5.5, takenAt: DateTime(2026, 6, 1), ageDays: 10);
      expect(g.canStartPlan, isTrue);
      expect(g.isFresh, isTrue);
      expect(g.recommendReassess, isFalse);
    });

    test('RF stantia → avvio consentito ma consiglia la ri-valutazione', () {
      final g = AssessmentGate(
          bpm: 5.5, takenAt: DateTime(2026, 1, 1), ageDays: 120);
      expect(g.canStartPlan, isTrue);
      expect(g.isFresh, isFalse);
      expect(g.recommendReassess, isTrue);
    });

    test('soglia di freschezza al limite', () {
      expect(
          AssessmentGate(bpm: 5.5, ageDays: kAssessmentValidityDays).isFresh,
          isTrue);
      expect(
          AssessmentGate(bpm: 5.5, ageDays: kAssessmentValidityDays + 1)
              .isFresh,
          isFalse);
    });
  });
}
