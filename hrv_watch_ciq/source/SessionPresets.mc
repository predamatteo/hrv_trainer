using Toybox.Lang as Lang;

// Preset di sessione standalone (avvio dal watch). Rispecchiano i SessionTag
// dell'app telefono (lib/shared/hrv/session_models.dart): stesso pacer clinico
// di default (Lehrer-Gevirtz 2014 / Shaffer 2017) e stessa durata consigliata.
//
// Il pacer è FISSO per preset; solo la durata è modificabile prima dell'avvio
// (vedi HrvTrainerView, modalità CFG_MODE_PRESET). L'ottavo elemento della
// lista mostrata all'utente — "Libero" — NON è qui: è il flusso manuale
// (inspira/espira/durata da zero) gestito in HrvTrainerView + SessionPrefs.
//
// inhaleMs/exhaleMs sono arrotondati al ms ESATTAMENTE come fa il telefono in
// START_SESSION ((durataSec*1000).round() applicato a BreathingPattern.fromBpm),
// così una sessione "Stress" avviata dall'orologio ha lo stesso ritmo di una
// avviata dall'app mobile.
//
// Indici coerenti con l'ordine dell'enum SessionTag lato telefono:
//   0 Mattino  1 Pre-workout  2 Post-workout  3 Sonno
//   4 Stress   5 Recupero     6 Generale
//
// Derivazione dei ritmi non-6bpm (I:E = 4:6):
//   Sonno   fromBpm(5.0) → periodo 12000ms → in 4800 / ex 7200
//   Stress/Recupero fromBpm(5.5) → periodo 10909ms → in 4364 / ex 6545
class SessionPresets {
    static const COUNT = 7;

    // Etichetta breve per la voce di menu e per la schermata durata.
    static function label(i) {
        switch (i) {
            case 0: return "Mattino";
            case 1: return "Pre-workout";
            case 2: return "Post-workout";
            case 3: return "Sonno";
            case 4: return "Stress";
            case 5: return "Recupero";
            default: return "Generale";
        }
    }

    // Sottotitolo della voce di menu: ritmo + durata consigliata. Separatore
    // "-" (ASCII) invece del "·" del telefono per garantire il rendering sul
    // set glifi ridotto dei font Instinct.
    static function subLabel(i) {
        switch (i) {
            case 0: return "6 bpm - 3 min";
            case 1: return "6 bpm - 5 min";
            case 2: return "6 bpm - 15 min";
            case 3: return "5 bpm - 10 min";
            case 4: return "5.5 bpm - 10 min";
            case 5: return "5.5 bpm - 20 min";
            default: return "6 bpm - 20 min";
        }
    }

    // Ritmo (solo display) mostrato nella schermata di modifica durata.
    static function bpmLabel(i) {
        switch (i) {
            case 3: return "5 bpm";
            case 4: return "5.5 bpm";
            case 5: return "5.5 bpm";
            default: return "6 bpm";
        }
    }

    static function inhaleMs(i) {
        switch (i) {
            case 3: return 4800;
            case 4: return 4364;
            case 5: return 4364;
            default: return 4000;   // 6 bpm: Mattino/Pre/Post/Generale
        }
    }

    static function exhaleMs(i) {
        switch (i) {
            case 3: return 7200;
            case 4: return 6545;
            case 5: return 6545;
            default: return 6000;
        }
    }

    // Durata consigliata in secondi (modificabile prima dell'avvio).
    static function durationSec(i) {
        switch (i) {
            case 0: return 180;    // Mattino    3 min
            case 1: return 300;    // Pre        5 min
            case 2: return 900;    // Post       15 min
            case 3: return 600;    // Sonno      10 min
            case 4: return 600;    // Stress     10 min
            case 5: return 1200;   // Recupero   20 min
            default: return 1200;  // Generale   20 min
        }
    }
}
