using Toybox.Math as Math;

// Configurazione del pacer respiratorio: durate in millisecondi.
// periodMs = somma di tutte e quattro le fasi.
class PacerInfo {
    var inhaleMs;
    var hold1Ms;
    var exhaleMs;
    var hold2Ms;
    var periodMs;

    function initialize(iMs, h1Ms, eMs, h2Ms) {
        inhaleMs = iMs;
        hold1Ms = h1Ms;
        exhaleMs = eMs;
        hold2Ms = h2Ms;
        periodMs = iMs + h1Ms + eMs + h2Ms;
        if (periodMs <= 0) { periodMs = 1; }
    }
}

// Stato istantaneo: fase corrente, progresso 0..1 dentro la fase,
// ampiezza 0..1 (0 = polmoni vuoti, 1 = polmoni pieni).
class PacerSnapshot {
    var phase;       // 0=inhale, 1=hold1, 2=exhale, 3=hold2
    var progress;
    var amplitude;

    function initialize(p, pr, a) {
        phase = p;
        progress = pr;
        amplitude = a;
    }
}

// Calcolatore puro: a partire da elapsedMs ritorna lo snapshot del pacer.
// Mantenuto come funzioni statiche per evitare allocazioni nel ticker UI.
class PacerCalc {
    static const PHASE_INHALE = 0;
    static const PHASE_HOLD1  = 1;
    static const PHASE_EXHALE = 2;
    static const PHASE_HOLD2  = 3;

    static function compute(info, elapsedMs) {
        var t = elapsedMs % info.periodMs;

        if (t < info.inhaleMs) {
            var r = t.toFloat() / info.inhaleMs;
            return new PacerSnapshot(PHASE_INHALE, r, smoothCos(r));
        }
        var c = info.inhaleMs;

        if (info.hold1Ms > 0 && t < c + info.hold1Ms) {
            var r = (t - c).toFloat() / info.hold1Ms;
            return new PacerSnapshot(PHASE_HOLD1, r, 1.0);
        }
        c += info.hold1Ms;

        if (t < c + info.exhaleMs) {
            var r = (t - c).toFloat() / info.exhaleMs;
            return new PacerSnapshot(PHASE_EXHALE, r, 1.0 - smoothCos(r));
        }
        c += info.exhaleMs;

        var r2 = info.hold2Ms > 0
            ? (t - c).toFloat() / info.hold2Ms
            : 0.0;
        return new PacerSnapshot(PHASE_HOLD2, r2, 0.0);
    }

    // Curva sinusoidale 0->1 con derivata nulla agli estremi.
    static function smoothCos(x) {
        if (x < 0.0) { x = 0.0; }
        if (x > 1.0) { x = 1.0; }
        return 0.5 - 0.5 * Math.cos(Math.PI * x);
    }

    static function phaseLabel(phase) {
        if (phase == PHASE_INHALE) { return "Inspira"; }
        if (phase == PHASE_HOLD1)  { return "Trattieni"; }
        if (phase == PHASE_EXHALE) { return "Espira"; }
        return "Pausa";
    }
}
