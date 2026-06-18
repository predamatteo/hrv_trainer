using Toybox.Sensor as Sensor;
using Toybox.System as Sys;
using Toybox.Time as Time;
using Toybox.Communications as Comm;
using Toybox.Math as Math;
using Toybox.Activity as Activity;
using Toybox.ActivityRecording as ActivityRecording;

// Sessione di campionamento HR: abilita il sensore HR, registra l'attività
// in formato FIT (visibile in Garmin Connect) e inoltra i campioni al
// telefono come HR_SAMPLE.
//
// Due modalità d'avvio:
//  - start(hz)         → sessione "phone-driven": il telefono raccoglie
//                         tutto in real-time, il watch è solo sensore.
//  - startLocal(hz, p) → sessione "stand-alone": il watch buffera RR
//                         localmente e produce un SESSION_SUMMARY con le
//                         metriche al termine, da inviare al telefono per
//                         il salvataggio in DB.
class HrSession {
    hidden var mActive;
    hidden var mView;
    hidden var mFitSession;
    hidden var mStartMs;
    // Epoch ms (Long: serve 64 bit per evitare overflow Int32 — vedi nota
    // in startInternal). Usato per "startMs" nel SESSION_SUMMARY.
    hidden var mStartEpochMs;
    // Epoch SECONDS (Number/Int32: ~1.76e9 nel 2026, ben dentro range).
    // Inviato in parallelo a startMs come safety-net: anche se in futuro un
    // calcolo lato watch reintroducesse un overflow su startMs, il phone può
    // ricostruire il timestamp corretto da startSec.
    hidden var mStartEpochSec;
    hidden var mBpmSum;
    hidden var mBpmCount;
    hidden var mRrList;
    hidden var mIsLocal;
    hidden var mPattern;
    // Echo del phoneTxMs ricevuto in START_SESSION. Restituito tal quale in
    // ogni HR_SAMPLE così il phone può stimare la latenza BT one-way e
    // allineare il proprio countdown a mStartMs di questo session.
    hidden var mPhoneTxMs;
    // Durata della fase di preparazione (ms). Inviata in HR_SAMPLE come
    // "pacerMs" = elapsedMs - mPrepMs (tempo di SESSIONE, negativo durante la
    // prep): è insieme il valore e il SEGNALE che questo watch supporta la prep
    // coordinata. Phone più vecchi (senza prep) non lo leggono; phone nuovi con
    // watch vecchio non lo ricevono e ricadono sul comportamento senza prep.
    hidden var mPrepMs;

    function initialize() {
        mActive = false;
        mView = null;
        mFitSession = null;
        mStartMs = 0;
        mStartEpochMs = 0l;
        mStartEpochSec = 0;
        mBpmSum = 0;
        mBpmCount = 0;
        mRrList = [];
        mIsLocal = false;
        mPattern = null;
        mPhoneTxMs = null;
        mPrepMs = 0;
    }

    function setView(v) { mView = v; }

    function setPhoneTxMs(txMs) { mPhoneTxMs = txMs; }

    // NB: il parametro hz è ignorato. Sull'Instinct Solar 2X
    // Sensor.setEnabledSensors non espone sample rate: il rate è ~1 Hz
    // di default. Mantenuto in firma per compatibilità col protocollo
    // di START_SESSION.
    //
    // recordFit: se true crea un'attività FIT che apparirà in Garmin
    // Connect come "Breathwork". Default false: lo storico HRV è già
    // gestito dall'app mobile, evitiamo duplicazione e il fastidioso
    // "Non sincronizzato" sul watch.
    function start(hz, recordFit, prepMs) {
        startInternal(false, null, recordFit, prepMs);
    }

    function startLocal(hz, pacer, recordFit) {
        // Standalone (avvio dal watch): nessuna prep.
        startInternal(true, pacer, recordFit, 0);
    }

    hidden function startInternal(isLocal, pacer, recordFit, prepMs) {
        Sys.println("HrSession.startInternal: enter isLocal=" + isLocal + " recordFit=" + recordFit);
        if (mActive) { return; }
        mActive = true;
        mIsLocal = isLocal;
        mPattern = pacer;
        mPrepMs = (prepMs != null) ? prepMs : 0;
        mStartMs = Sys.getTimer();
        // Time.now().value() ritorna Number (Int32 signed): epoch seconds
        // = ~1.76e9 nel 2026, dentro range. Ma `Number * Number` in Monkey C
        // resta Number e wrappa silenziosamente in overflow: 1.76e9 * 1000
        // = 1.76e12, ben oltre Int32 max (2.147e9). Risultato wrap: valore
        // garbled negativo. Le sessioni standalone con questo bug finivano
        // salvate sul phone con startedAt ~ gennaio 1906 e quindi invisibili
        // nello storico filtrato per "ultimi 30 giorni".
        // Fix: promuovere a Long con .toLong() così che la moltiplicazione
        // sia 64-bit (Long * Number → Long, range fino a 9.2e18).
        mStartEpochSec = Time.now().value();
        mStartEpochMs = mStartEpochSec.toLong() * 1000l;
        mBpmSum = 0;
        mBpmCount = 0;
        mRrList = [];

        try {
            Sensor.setEnabledSensors([ Sensor.SENSOR_HEARTRATE ]);
            Sys.println("HrSession.startInternal: sensors enabled");
        } catch (ex) {
            Sys.println("HrSession.startInternal: setEnabledSensors FAIL " + ex.getErrorMessage());
        }
        try {
            Sensor.enableSensorEvents(method(:onSensor));
            Sys.println("HrSession.startInternal: sensor events on");
        } catch (ex) {
            Sys.println("HrSession.startInternal: enableSensorEvents FAIL " + ex.getErrorMessage());
        }

        if (recordFit == true) {
            startFit();
        } else {
            Sys.println("HrSession.startInternal: FIT recording skipped");
        }
        Sys.println("HrSession.startInternal: done");
    }

    // Avvia la registrazione FIT (visibile in Garmin Connect come attività
    // "HRV Trainer"). Capability check perché alcuni device non supportano
    // ActivityRecording, e altri non hanno SUB_SPORT_BREATHWORK definito.
    hidden function startFit() {
        if (!(Toybox has :ActivityRecording)) { return; }
        try {
            var subSport = (Activity has :SUB_SPORT_BREATHWORK)
                ? Activity.SUB_SPORT_BREATHWORK
                : Activity.SUB_SPORT_GENERIC;
            mFitSession = ActivityRecording.createSession({
                :name => "HRV Trainer",
                :sport => Activity.SPORT_TRAINING,
                :subSport => subSport,
            });
            mFitSession.start();
        } catch (ex) {
            mFitSession = null;
        }
    }

    // Ferma sensore e registrazione. Ritorna il summary se la sessione era
    // locale (mIsLocal=true), altrimenti null.
    function stopIfActive() {
        if (!mActive) { return null; }
        Sensor.enableSensorEvents(null);
        Sensor.setEnabledSensors([]);
        mActive = false;

        var durationMs = Sys.getTimer() - mStartMs;

        if (mFitSession != null) {
            try { mFitSession.stop(); } catch (ex) {}
            if (durationMs >= 30000) {
                try { mFitSession.save(); }
                catch (ex) { try { mFitSession.discard(); } catch (ex2) {} }
            } else {
                try { mFitSession.discard(); } catch (ex) {}
            }
            mFitSession = null;
        }

        var summary = mIsLocal ? buildSummary(durationMs) : null;
        mIsLocal = false;
        mPattern = null;
        return summary;
    }

    // Abort: ferma tutto SCARTANDO sempre il FIT e senza produrre summary.
    // Usato dal tasto BACK quando l'utente vuole annullare la sessione.
    function discardIfActive() {
        if (!mActive) { return; }
        Sys.println("HrSession.discardIfActive");
        try { Sensor.enableSensorEvents(null); } catch (ex) {}
        try { Sensor.setEnabledSensors([]); } catch (ex) {}
        mActive = false;

        if (mFitSession != null) {
            try { mFitSession.stop(); } catch (ex) {}
            try { mFitSession.discard(); } catch (ex) {}
            mFitSession = null;
        }
        mIsLocal = false;
        mPattern = null;
        mRrList = [];
        mBpmSum = 0;
        mBpmCount = 0;
    }

    hidden function buildSummary(durationMs) {
        var n = mRrList.size();
        var meanHr = (mBpmCount > 0) ? (mBpmSum / mBpmCount).toNumber() : 0;
        var sdnn = 0;
        var rmssd = 0;
        // Gate fisiologico (300-2000 ms) + anti-spike (|delta|>250 ms) PRIMA
        // delle statistiche: un singolo HR sample droppato/spurio gonfierebbe
        // RMSSD/SDNN, mostrati standalone e usati come seed lato telefono.
        var clean = [];
        var prevc = null;
        for (var c = 0; c < n; c++) {
            var v = mRrList[c];
            if (v < 300 || v > 2000) { continue; }
            if (prevc != null && (v - prevc).abs() > 250) { continue; }
            clean.add(v);
            prevc = v;
        }
        var cn = clean.size();
        if (cn >= 10) {
            var sum = 0;
            for (var i = 0; i < cn; i++) { sum += clean[i]; }
            var mean = sum.toFloat() / cn;
            var sq = 0.0;
            for (var j = 0; j < cn; j++) {
                var d = clean[j] - mean;
                sq += d * d;
            }
            // Sample stdev (n-1) per coerenza con la letteratura HRV.
            sdnn = Math.sqrt(sq / (cn - 1)).toNumber();
            var sqd = 0.0;
            for (var k = 1; k < cn; k++) {
                var dk = clean[k] - clean[k - 1];
                sqd += dk * dk;
            }
            rmssd = Math.sqrt(sqd / (cn - 1)).toNumber();
        }
        // durationMs.toLong() forza somma in 64-bit così endMs non rischia
        // overflow (durationMs è Number ma 1.76e12 + 1.2e6 va calcolato Long).
        var endEpochMs = mStartEpochMs + durationMs.toLong();
        var summary = {
            "type" => "SESSION_SUMMARY",
            "startMs" => mStartEpochMs,
            "endMs" => endEpochMs,
            // startSec / endSec: epoch SECONDS (Int32-safe). Inviati come
            // safety-net in caso di overflow su startMs/endMs lato watch o
            // di Long mal-serializzato sul canale CIQ Mobile. Il phone preferisce
            // startSec quando entrambi sono presenti e plausibili — vedi
            // remote_session_summary.dart#_pickStartedAt.
            "startSec" => mStartEpochSec,
            "endSec" => mStartEpochSec + (durationMs / 1000),
            "durationMs" => durationMs.toNumber(),
            "samples" => n,
            "meanHr" => meanHr,
            "sdnn" => sdnn,
            "rmssd" => rmssd,
            "rr" => mRrList,
            // RR derivati da HR aggregato (~1 Hz su Instinct Solar 2X),
            // non da intervalli battito-battito reali. Il telefono deve
            // marcare le metriche HRV come stima.
            "rrSource" => "estimated_from_hr",
        };
        if (mPattern != null) {
            summary.put("inhaleMs", mPattern.inhaleMs);
            summary.put("exhaleMs", mPattern.exhaleMs);
            summary.put("hold1Ms", mPattern.hold1Ms);
            summary.put("hold2Ms", mPattern.hold2Ms);
        }
        return summary;
    }

    // Invocato dal framework a ogni update del Sensor (~1 Hz su Instinct 2X).
    hidden var mSensorCount = 0;
    function onSensor(info as Sensor.Info) as Void {
        if (info == null) { return; }
        var bpm = info.heartRate;
        mSensorCount++;
        if (mSensorCount % 5 == 1) {
            Sys.println("onSensor #" + mSensorCount + " bpm=" + bpm);
        }
        if (bpm == null || bpm <= 0) { return; }
        var rr = 60000 / bpm;

        mBpmSum += bpm;
        mBpmCount += 1;
        mRrList.add(rr);

        var payload = {
            "type" => "HR_SAMPLE",
            // .toLong() per evitare overflow Int32 (vedi nota in startInternal).
            // Il phone usa DateTime.now() come timestamp di arrivo, non `t` —
            // ma manteniamo il campo corretto per consistenza con il protocollo.
            "t" => Time.now().value().toLong() * 1000l,
            "bpm" => bpm,
            "rr" => rr,
            // Vedi nota in buildSummary: rr è 60000/bpm, non R-R reale.
            "rrSource" => "estimated_from_hr",
            // Tempo trascorso dall'avvio sessione watch (ms). Permette al
            // phone di allineare il proprio countdown a quello del watch
            // sul primo HR_SAMPLE: il watch fissa mStartMs appena riceve
            // START_SESSION, mentre il primo battito può arrivare al phone
            // 3-5 s dopo (attivazione sensore HR ~1 Hz + latenza BT). Senza
            // questo campo i due countdown divergono di quel delta.
            "elapsedMs" => Sys.getTimer() - mStartMs,
            // Tempo di SESSIONE = elapsed meno la prep (negativo durante la
            // prep). Il phone vi aggancia l'orb del respiro guida; la sua
            // presenza segnala anche che questo watch supporta la prep
            // coordinata (assente sui watch vecchi → phone ricade su no-prep).
            "pacerMs" => (Sys.getTimer() - mStartMs) - mPrepMs,
            // Echo del phoneTxMs ricevuto in START_SESSION. Il phone calcola:
            //   roundTrip = now - phoneTxMs
            //   oneWayMs ≈ (roundTrip - elapsedMs) / 2     [simmetria up/down]
            //   t0       = phoneTxMs + oneWayMs            [in coordinate phone]
            // Senza questo campo il phone correggeva solo l'attivazione del
            // sensore HR ma non la latenza BT del primo sample (residuo 1-2 s).
            "phoneTxMs" => mPhoneTxMs,
        };
        try {
            Comm.transmit(payload, null, new CommListener());
        } catch (ex) {
            // BT giù / phone non connesso: continuiamo comunque a campionare.
        }
        if (mView != null) { mView.setBpm(bpm); }
    }

    function isActive() { return mActive; }
    function isLocal() { return mIsLocal; }

    // Epoch ms d'avvio dell'ultima sessione (resta valorizzato anche dopo lo
    // stop, fino al prossimo start). Usato come chiave di correlazione
    // nell'ACK STATE:READY(stopped) verso il telefono.
    function getStartEpochMs() { return mStartEpochMs; }
}
