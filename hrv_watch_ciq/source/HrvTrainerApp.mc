using Toybox.Application as App;
using Toybox.WatchUi as Ui;
using Toybox.Communications as Comm;
using Toybox.Lang as Lang;
using Toybox.System as Sys;

// Entry point dell'app Connect IQ per l'Instinct Solar 2X.
// Orchestra sessione HR + risposte HRV on-demand verso il telefono e
// supporta anche modalità stand-alone (avvio dal watch).
class HrvTrainerApp extends App.AppBase {
    var mView;
    var mSession;

    // I default per la sessione standalone (durata + pacer) vivono in
    // SessionPrefs.mc. Sono modificabili dall'utente attraverso il pannello
    // CONFIG sul watch (GPS dalla schermata idle).
    //
    // NB: le sessioni phone-driven (START_SESSION via BT) NON leggono da
    // SessionPrefs: continuano a usare i parametri inviati dal telefono.
    // Quindi modificare la config sul watch non influisce in alcun modo
    // sull'esperienza con l'app mobile.

    // FIT recording: se true, ogni sessione locale produce un'attività
    // "Breathwork" in Garmin Connect. Default false per evitare di
    // duplicare lo storico (l'app mobile gestisce già SDNN/RMSSD).
    // Cambiare a true se serve backup ridondante in Garmin Connect.
    static const LOCAL_RECORD_FIT = false;

    function initialize() {
        AppBase.initialize();
        mSession = new HrSession();
        // IMPORTANTE: la view va creata qui, NON in getInitialView().
        // Connect IQ chiama initialize() → onStart() → getInitialView().
        // Se la registriamo in onStart, può arrivare un messaggio dal phone
        // prima di getInitialView e mView risulterebbe null nel callback.
        mView = new HrvTrainerView();
        mSession.setView(mView);
    }

    function onStart(state) {
        Sys.println("App.onStart");
        try {
            Comm.registerForPhoneAppMessages(method(:onPhoneMessage));
            Sys.println("App.onStart: phone msg registered");
        } catch (ex) {
            // Su firmware vecchi o senza Communications inizializzato
            // questo può lanciare. Non deve impedire l'uso standalone.
            Sys.println("App.onStart: registerForPhoneAppMessages FAIL " + ex.getErrorMessage());
        }
        // Riprova a consegnare summary di sessioni precedenti che non hanno
        // ancora ricevuto SUMMARY_ACK dal telefono (es. app Android killata
        // al momento dello stop). Best-effort: se BT è giù fallisce zitto.
        flushPendingSummaries();
    }

    function onStop(state) {
        // Se l'app si ferma con una sessione locale attiva, salva quanto fatto.
        requestStop();
    }

    function getInitialView() {
        return [ mView, new HrvTrainerDelegate() ];
    }

    // === Avvio/stop locali (chiamati da delegate o auto-stop del view) =====

    function requestStartLocal() {
        Sys.println("requestStartLocal: enter");
        if (mSession.isActive()) {
            Sys.println("requestStartLocal: already active, exit");
            return;
        }
        // Legge config corrente. Se l'utente non ha mai aperto il pannello,
        // SessionPrefs ritorna i propri DEFAULT_* (5 min @ 4s/6s, no hold).
        var inhaleMs = SessionPrefs.getInhaleMs();
        var exhaleMs = SessionPrefs.getExhaleMs();
        var hold1Ms  = SessionPrefs.getHold1Ms();
        var hold2Ms  = SessionPrefs.getHold2Ms();
        var durSec   = SessionPrefs.getDurationSec();
        var pacer = new PacerInfo(inhaleMs, hold1Ms, exhaleMs, hold2Ms);
        Sys.println("requestStartLocal: pacer ready dur=" + durSec
            + " in=" + inhaleMs + " ex=" + exhaleMs);
        try {
            mSession.startLocal(4, pacer, LOCAL_RECORD_FIT);
            Sys.println("requestStartLocal: session started");
        } catch (ex) {
            Sys.println("requestStartLocal: session FAIL " + ex.getErrorMessage());
            return;
        }
        if (mView != null) {
            try {
                mView.startSession(pacer, durSec);
                Sys.println("requestStartLocal: view started");
            } catch (ex) {
                Sys.println("requestStartLocal: view FAIL " + ex.getErrorMessage());
            }
        } else {
            Sys.println("requestStartLocal: mView NULL");
        }
        sendPhone({
            "type" => "STATE",
            "v" => "ACTIVE",
            "origin" => "watch",
        });
        Sys.println("requestStartLocal: done");
    }

    function requestStop() {
        Sys.println("requestStop: enter");
        if (!mSession.isActive()) {
            Sys.println("requestStop: not active, exit");
            return;
        }
        var summary = null;
        try {
            summary = mSession.stopIfActive();
        } catch (ex) {
            Sys.println("requestStop: session stop FAIL " + ex.getErrorMessage());
        }
        if (mView != null) {
            try { mView.stopSession(); }
            catch (ex) { Sys.println("requestStop: view stop FAIL " + ex.getErrorMessage()); }
        }
        sendPhone({ "type" => "STATE", "v" => "READY" });
        if (summary != null) {
            // 1) Persistiamo SEMPRE prima di trasmettere: se BT è giù,
            //    Comm.transmit fallisce ma il summary resta in Storage e
            //    sarà ritrasmesso al prossimo avvio / messaggio dal phone.
            // 2) Lo Storage si svuota solo quando il phone risponde con
            //    SUMMARY_ACK matchando lo startMs.
            Sys.println("requestStop: summary built startMs=" + summary["startMs"]
                + " samples=" + summary["samples"]
                + " durationMs=" + summary["durationMs"]);
            try { PendingStore.add(summary); }
            catch (ex) { Sys.println("requestStop: PendingStore.add FAIL " + ex.getErrorMessage()); }
            sendPhone(summary);
            Sys.println("requestStop: summary transmit dispatched, pending=" + PendingStore.size());
        } else {
            Sys.println("requestStop: WARN summary null (mIsLocal era false?)");
        }
        Sys.println("requestStop: done");
    }

    // Abort sessione: BACK premuto durante una sessione attiva.
    // Differenze rispetto a requestStop:
    //  - il FIT viene SEMPRE scartato (mai salvato in Garmin Connect)
    //  - nessun SESSION_SUMMARY inviato al telefono → non finisce nello storico
    //  - viene mandato STATE=READY con flag aborted=true così l'app mobile
    //    può aggiornare la UI senza creare una sessione nel DB
    function requestAbort() {
        Sys.println("requestAbort: enter");
        if (!mSession.isActive()) {
            Sys.println("requestAbort: not active, exit");
            return;
        }
        try {
            mSession.discardIfActive();
        } catch (ex) {
            Sys.println("requestAbort: discard FAIL " + ex.getErrorMessage());
        }
        if (mView != null) {
            try { mView.stopSession(); }
            catch (ex) { Sys.println("requestAbort: view stop FAIL " + ex.getErrorMessage()); }
        }
        sendPhone({
            "type" => "STATE",
            "v" => "READY",
            "aborted" => true,
            "origin" => "watch",
        });
        Sys.println("requestAbort: done");
    }

    function isActive() {
        return mSession != null && mSession.isActive();
    }

    // Esposto per il delegate, che lo usa per pilotare la state machine UI
    // del pannello CONFIG (enter/exit/select/nudge). Tenuto qui invece di
    // far accedere `mView` direttamente, così se in futuro la View viene
    // ricreata a runtime non ci sono riferimenti stale dentro al delegate.
    function getView() {
        return mView;
    }

    // === Messaggi dal telefono ============================================

    function onPhoneMessage(msg as Comm.PhoneAppMessage) as Void {
        var d = msg.data;
        Sys.println("onPhoneMessage data=" + d);
        if (d == null || !(d instanceof Lang.Dictionary)) { return; }

        var type = d["type"];
        Sys.println("onPhoneMessage type=" + type);
        if (type == null) { return; }

        // Il phone ci ha appena scritto → BT funziona ora. È un buon momento
        // per provare a consegnare eventuali summary in coda.
        flushPendingSummaries();

        if (type.equals("START_SESSION")) {
            var hz = d["hz"]; if (hz == null) { hz = 4; }
            // recordFit opzionale: se true il watch crea anche un'attività
            // FIT in Garmin Connect. Default false (storico già su phone).
            var recFit = d["recordFit"];
            if (recFit == null) { recFit = false; }
            mSession.start(hz, recFit);
            // phoneTxMs: epoch ms del phone catturato lato bridge Kotlin
            // immediatamente prima di sendMessage. Ritrasmesso in ogni
            // HR_SAMPLE per permettere al phone di stimare la latenza BT
            // one-way ((roundTrip - elapsedMs) / 2) e allineare il proprio
            // countdown al ms con quello del watch.
            mSession.setPhoneTxMs(d["phoneTxMs"]);

            // Pacer params (opzionali). Se forniti il view fa countdown +
            // cerchio respiro + vibrazione locali, senza dover ricevere
            // tick continui dal telefono.
            var pacer = null;
            var iMs = d["inhaleMs"];
            var eMs = d["exhaleMs"];
            if (iMs != null && eMs != null) {
                var h1 = d["hold1Ms"]; if (h1 == null) { h1 = 0; }
                var h2 = d["hold2Ms"]; if (h2 == null) { h2 = 0; }
                pacer = new PacerInfo(iMs, h1, eMs, h2);
            }
            var dur = d["durationSec"];
            if (mView != null) {
                mView.startSession(pacer, dur);
            } else {
                Sys.println("onPhoneMessage: mView NULL on START_SESSION");
            }
            sendPhone({ "type" => "STATE", "v" => "ACTIVE" });
        } else if (type.equals("STOP_SESSION")) {
            requestStop();
        } else if (type.equals("REQUEST_HRV")) {
            var reqId = d["reqId"];
            HrvCompute.computeAndReply(reqId);
        } else if (type.equals("SUMMARY_ACK")) {
            // Conferma di ricezione di un SESSION_SUMMARY da parte del
            // phone. startMs identifica univocamente la sessione.
            // Solo a questo punto è sicuro rimuoverlo dal pending store.
            var ackedStart = d["startMs"];
            PendingStore.ack(ackedStart);
        } else if (type.equals("SYNC_REQUEST")) {
            // Il phone chiede esplicitamente di drenare il PendingStore.
            // È il salvagente quando l'app phone era killata al momento
            // del SESSION_SUMMARY originale: Garmin Connect Mobile non
            // bufferizza i messaggi se il listener (registerForAppEvents)
            // non era registrato in quel momento. Senza un trigger come
            // questo, il summary resta orfano in Storage finché l'utente
            // non apre l'app sul watch dal launcher (che fa onStart →
            // flush) o avvia una nuova sessione dal phone.
            //
            // NB: il flush è già implicito sopra (qualunque messaggio
            // dal phone scatena flushPendingSummaries). Tenere il case
            // esplicito serve come hook documentato e per evitare che
            // futuri filtri "ignora type sconosciuti" scartino il sync.
            Sys.println("onPhoneMessage: SYNC_REQUEST received");
        }
    }

    // Best-effort: ritrasmette tutti i SESSION_SUMMARY non ancora confermati.
    // Comm.transmit è asincrono — se BT è giù fallisce silenziosamente e
    // i summary restano in Storage per il prossimo tentativo.
    hidden function flushPendingSummaries() {
        var pending = PendingStore.getAll();
        if (pending.size() == 0) {
            Sys.println("flushPendingSummaries: no pending");
            return;
        }
        Sys.println("flushPendingSummaries: count=" + pending.size());
        for (var i = 0; i < pending.size(); i++) {
            var s = pending[i];
            if (s instanceof Toybox.Lang.Dictionary) {
                Sys.println("  -> retransmit startMs=" + s["startMs"]
                    + " samples=" + s["samples"]);
            }
            sendPhone(s);
        }
    }

    // === Trasmissione al telefono =========================================

    static function sendPhone(payload) {
        // Comm.transmit dovrebbe essere asincrono ma su alcuni firmware
        // Instinct se il phone non è connesso lancia sincrono. Avvolto
        // in try così l'app standalone non crasha senza telefono.
        try {
            Comm.transmit(payload, null, new CommListener());
        } catch (ex) {
            Sys.println("sendPhone: transmit FAIL " + ex.getErrorMessage());
        }
    }
}

class CommListener extends Comm.ConnectionListener {
    function initialize() { ConnectionListener.initialize(); }
    function onComplete() {}
    function onError() {}
}
