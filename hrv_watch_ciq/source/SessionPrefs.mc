using Toybox.Application as App;
using Toybox.Application.Storage as Storage;
using Toybox.Lang as Lang;
using Toybox.System as Sys;

// Preferenze persistenti per la modalità di sessione standalone (avviata
// dal watch tramite il flusso GPS → CONFIG → SELECT su "Avvia").
//
// Tutto vive in Application.Storage. Le sessioni phone-driven (START_SESSION
// dal telefono) NON leggono da qui: continuano a usare i parametri inviati
// nel messaggio. Quindi modificare questi default non altera in alcun modo
// l'esperienza con l'app mobile.
//
// I valori sono clampati al momento del set per evitare che valori corrotti
// in Storage producano periodi pacer pari a 0 (divisione per zero in
// PacerCalc.compute) o sessioni di durata folle.
class SessionPrefs {
    // Chiavi Storage.
    static const KEY_DUR  = "cfgDurationSec";
    static const KEY_IN   = "cfgInhaleMs";
    static const KEY_EX   = "cfgExhaleMs";
    static const KEY_H1   = "cfgHold1Ms";
    static const KEY_H2   = "cfgHold2Ms";

    // Default coerenti con i DEFAULT_* di HrvTrainerApp originali, così
    // chi non entra mai nel pannello config vede comportamento invariato.
    static const DEFAULT_DUR_SEC  = 300;   // 5 min
    static const DEFAULT_INHALE   = 4000;
    static const DEFAULT_EXHALE   = 6000;
    static const DEFAULT_HOLD1    = 0;
    static const DEFAULT_HOLD2    = 0;

    // Range UI. Vedi commento sui choice in cima al file.
    static const DUR_MIN_SEC  = 60;        // 1 min
    static const DUR_MAX_SEC  = 60 * 60;   // 60 min
    static const DUR_STEP_SEC = 60;        // 1 min

    // Pacer in millisecondi, step 500 ms = 0.5 s (granularità sufficiente
    // per la respirazione di risonanza, evita di intasare la UI).
    static const PHASE_MIN_MS    = 1000;     // 1.0 s minimo per inhale/exhale
    static const PHASE_MAX_MS    = 15000;    // 15.0 s
    static const HOLD_MIN_MS     = 0;
    static const HOLD_MAX_MS     = 10000;    // 10.0 s
    static const PHASE_STEP_MS   = 500;      // 0.5 s

    // === Getter (con fallback ai default) ================================

    static function getDurationSec() {
        return readClamped(KEY_DUR, DEFAULT_DUR_SEC, DUR_MIN_SEC, DUR_MAX_SEC);
    }

    static function getInhaleMs() {
        return readClamped(KEY_IN, DEFAULT_INHALE, PHASE_MIN_MS, PHASE_MAX_MS);
    }

    static function getExhaleMs() {
        return readClamped(KEY_EX, DEFAULT_EXHALE, PHASE_MIN_MS, PHASE_MAX_MS);
    }

    static function getHold1Ms() {
        return readClamped(KEY_H1, DEFAULT_HOLD1, HOLD_MIN_MS, HOLD_MAX_MS);
    }

    static function getHold2Ms() {
        return readClamped(KEY_H2, DEFAULT_HOLD2, HOLD_MIN_MS, HOLD_MAX_MS);
    }

    // === Setter con clamp ================================================

    static function setDurationSec(sec) {
        writeClamped(KEY_DUR, sec, DUR_MIN_SEC, DUR_MAX_SEC);
    }

    static function setInhaleMs(ms) {
        writeClamped(KEY_IN, ms, PHASE_MIN_MS, PHASE_MAX_MS);
    }

    static function setExhaleMs(ms) {
        writeClamped(KEY_EX, ms, PHASE_MIN_MS, PHASE_MAX_MS);
    }

    static function setHold1Ms(ms) {
        writeClamped(KEY_H1, ms, HOLD_MIN_MS, HOLD_MAX_MS);
    }

    static function setHold2Ms(ms) {
        writeClamped(KEY_H2, ms, HOLD_MIN_MS, HOLD_MAX_MS);
    }

    // === Helpers privati =================================================

    hidden static function readClamped(key, def, lo, hi) {
        var v = Storage.getValue(key);
        if (!(v instanceof Lang.Number)) { return def; }
        if (v < lo) { return lo; }
        if (v > hi) { return hi; }
        return v;
    }

    hidden static function writeClamped(key, value, lo, hi) {
        if (!(value instanceof Lang.Number)) { return; }
        var v = value;
        if (v < lo) { v = lo; }
        if (v > hi) { v = hi; }
        try {
            Storage.setValue(key, v);
        } catch (ex) {
            // Storage può fallire se quasi pieno. Non vogliamo crashare:
            // la prossima sessione userà semplicemente il valore precedente
            // o il default.
            Sys.println("SessionPrefs.write FAIL " + ex.getErrorMessage());
        }
    }
}
