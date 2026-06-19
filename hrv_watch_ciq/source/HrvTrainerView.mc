using Toybox.WatchUi as Ui;
using Toybox.Graphics as Gfx;
using Toybox.Timer as Timer;
using Toybox.System as Sys;
using Toybox.Attention as Att;
using Toybox.Application as App;

// View principale dell'app sul watch.
//
// Tre schermate possibili (mScreen):
//  - SCREEN_IDLE   → "Ready" + hint per entrare in config
//  - SCREEN_CONFIG → pannello di configurazione standalone (durata + pacer)
//  - SCREEN_ACTIVE → sessione in corso (countdown + cerchio respiro + HR)
//
// Le sessioni avviate dal telefono (START_SESSION via BT) saltano CONFIG
// e vanno direttamente in ACTIVE: la View non interpreta SessionPrefs in
// quel caso, usa solo i parametri passati a startSession().
//
// Tutto è calcolato localmente: il telefono manda solo i parametri pacer
// dentro START_SESSION, così non c'è dipendenza da messaggi BT continui.
class HrvTrainerView extends Ui.View {
    // === Stato schermata ===
    static const SCREEN_IDLE   = 0;
    static const SCREEN_CONFIG = 1;
    static const SCREEN_ACTIVE = 2;
    hidden var mScreen;

    // Margine di backup (ms) aggiunto all'auto-stop SOLO per le sessioni
    // phone-driven: il telefono è il driver e invia lo STOP a fine durata,
    // quindi il nostro auto-stop deve restare un salvagente che NON tronchi la
    // finestra del telefono (senza margine il sensore si spegneva un attimo
    // prima che lo STOP arrivasse via BT, perdendo gli ultimi battiti). Il
    // countdown a schermo usa la durata pura (mDurationSec), così resta
    // allineato al telefono e tocca 0:00 quando arriva lo STOP — questo margine
    // sposta solo PIÙ AVANTI il backstop, non il numero mostrato. Sulle sessioni
    // standalone (avvio dal watch) il margine è 0: lì l'auto-stop è lo stop vero
    // e con margine la sessione durerebbe più del configurato.
    static const AUTOSTOP_BACKUP_GUARD_MS = 10000;

    // === Stato sessione attiva (SCREEN_ACTIVE) ===
    hidden var mActive;
    hidden var mPacer;
    hidden var mStartMs;
    hidden var mDurationSec;
    // Fase di preparazione (ms): per i primi mPrepMs dopo START l'orologio resta
    // SILENZIOSO (nessun cerchio respiro, nessuna vibrazione) e mostra
    // "Preparati", poi parte a regime. Allinea l'avvio del respiro con il
    // telefono e copre warm-up sensore + connessione. 0 = nessuna prep
    // (sessioni standalone e check-in mattutino).
    hidden var mPrepMs;
    hidden var mBpm;
    hidden var mSnapshot;
    hidden var mLastPhase;
    hidden var mTicker;
    // Contatore tick (5 Hz) con telefono disconnesso durante una sessione
    // phone-driven; oltre la soglia il watchdog aborta. Vedi checkPhoneLost().
    hidden var mPhoneLostTicks;

    // === Stato pannello config (SCREEN_CONFIG) ===
    //
    // Carosello a una pagina per volta: indispensabile sull'Instinct perché
    // il sub-display circolare in alto a destra (~x=102..168, y=2..68)
    // nasconderebbe i valori di una lista renderizzata a destra. Mostriamo
    // un solo parametro alla volta, valore grande centrato in zona safe
    // (y > 68), MENU/ABC modifica direttamente, GPS avanza al successivo.
    //
    // Pagine: 0=Durata, 1=Inspira, 2=Espira, 3=Avvia.
    //
    // Hold1 (trattieni a polmoni pieni) e Hold2 (pausa a polmoni vuoti)
    // NON sono esposti qui: l'app phone non li espone (usa sempre il
    // pattern di risonanza 4/6 senza hold), e il training HRV stile
    // Lehrer-Gevirtz prevede respirazione sinusoidale fluida senza pause.
    // Il protocollo end-to-end (PacerInfo, START_SESSION, SESSION_SUMMARY)
    // li supporta comunque, così se in futuro la phone vorrà aggiungerli
    // sarà sufficiente esporli lì.
    static const CFG_PAGE_DURATION = 0;
    static const CFG_PAGE_INHALE   = 1;
    static const CFG_PAGE_EXHALE   = 2;
    static const CFG_PAGE_START    = 3;
    static const CFG_PAGE_COUNT    = 4;

    hidden var mPageIdx;

    function initialize() {
        View.initialize();
        mScreen = SCREEN_IDLE;
        mActive = false;
        mPacer = null;
        mStartMs = 0;
        mDurationSec = null;
        mPrepMs = 0;
        mBpm = null;
        mSnapshot = null;
        mLastPhase = -1;
        mTicker = null;
        mPageIdx = 0;
        mPhoneLostTicks = 0;
    }

    // === API per HrvTrainerApp =============================================

    // Chiamato dall'app quando arriva START_SESSION (dal telefono o locale).
    // prepMs: durata della fase di preparazione silenziosa (0 = nessuna).
    function startSession(pacer, durationSec, prepMs) {
        mScreen = SCREEN_ACTIVE;
        mActive = true;
        mPacer = pacer;
        mDurationSec = durationSec;
        mPrepMs = (prepMs != null) ? prepMs : 0;
        mStartMs = Sys.getTimer();
        mBpm = null;
        mLastPhase = -1;
        mSnapshot = null;
        mPhoneLostTicks = 0;
        if (mTicker == null) {
            mTicker = new Timer.Timer();
            // 200 ms = 5 Hz: sufficiente per cerchio respiro su display
            // monocromatico, dimezza il carico di Ui.requestUpdate.
            mTicker.start(method(:onTick), 200, true);
        }
        Ui.requestUpdate();
    }

    function stopSession() {
        mActive = false;
        mScreen = SCREEN_IDLE;
        if (mTicker != null) {
            mTicker.stop();
            mTicker = null;
        }
        Ui.requestUpdate();
    }

    function setBpm(bpm) {
        mBpm = bpm;
        Ui.requestUpdate();
    }

    // Ingresso pannello config: ammesso solo da IDLE. Se la sessione è
    // attiva l'azione viene ignorata (il delegate non dovrebbe chiamarci
    // in quel caso, ma è una guardia di sicurezza).
    function enterConfig() {
        if (mScreen != SCREEN_IDLE) { return; }
        mScreen = SCREEN_CONFIG;
        mPageIdx = 0;
        Ui.requestUpdate();
    }

    function exitConfig() {
        if (mScreen == SCREEN_CONFIG) {
            mScreen = SCREEN_IDLE;
            Ui.requestUpdate();
        }
    }

    function isConfigOpen() {
        return mScreen == SCREEN_CONFIG;
    }

    // UP/DOWN nel pannello config: modifica direttamente il valore del
    // parametro corrente (no edit-mode toggling). Sulla pagina "Avvia"
    // non c'è nulla da modificare e l'evento viene ignorato.
    // delta è in step "logici" (+1/-1); la conversione in unità di misura
    // (sec o ms) è fatta da adjustValueForPage().
    function configNudge(delta) {
        if (mScreen != SCREEN_CONFIG) { return; }
        if (mPageIdx == CFG_PAGE_START) { return; }
        adjustValueForPage(mPageIdx, delta);
        Ui.requestUpdate();
    }

    // SELECT nel pannello config:
    //  - su una pagina parametro → avanza alla pagina successiva
    //  - sulla pagina "Avvia" → start sessione standalone
    function configSelect() {
        if (mScreen != SCREEN_CONFIG) { return; }
        if (mPageIdx == CFG_PAGE_START) {
            // requestStartLocal() leggerà SessionPrefs e chiamerà
            // view.startSession() che porta mScreen a SCREEN_ACTIVE.
            App.getApp().requestStartLocal();
            return;
        }
        mPageIdx = mPageIdx + 1;
        if (mPageIdx >= CFG_PAGE_COUNT) { mPageIdx = 0; }
        Ui.requestUpdate();
    }

    // LIGHT (tasto CTRL su Instinct) nel pannello config: pagina precedente.
    // Mappato dal delegate via onKey(KEY_LIGHT). Se l'OS intercetta il tasto
    // (Controls menu) la chiamata semplicemente non arriva: degradazione
    // soft, l'utente può comunque scorrere in avanti con GPS.
    function configPrevPage() {
        if (mScreen != SCREEN_CONFIG) { return; }
        var p = mPageIdx - 1;
        if (p < 0) { p = CFG_PAGE_COUNT - 1; }
        mPageIdx = p;
        Ui.requestUpdate();
    }

    // === Tick locale a 5 Hz (solo SCREEN_ACTIVE) ==========================

    function onTick() as Void {
        if (!mActive) { return; }

        var elapsedMs = Sys.getTimer() - mStartMs;
        // Tempo di SESSIONE (esclusa la prep): negativo durante la prep.
        var pacerMs = elapsedMs - mPrepMs;

        // Auto-stop al raggiungimento della durata target, contata sul tempo di
        // sessione: il tempo attivo totale è prep + durata. Delegato all'app
        // così che faccia anche FIT save + invio SESSION_SUMMARY se locale.
        // Per le sessioni phone-driven aggiungiamo AUTOSTOP_BACKUP_GUARD_MS: il
        // telefono ferma a fine durata e questo auto-stop è solo un backup che
        // non deve troncare la sua finestra. Standalone → guardia 0 (qui
        // l'auto-stop è lo stop vero). Il countdown a schermo usa mDurationSec
        // puro, quindi resta allineato al telefono indipendentemente da questo
        // margine.
        if (mDurationSec != null) {
            var guardMs = App.getApp().isPhoneDrivenActive()
                ? AUTOSTOP_BACKUP_GUARD_MS : 0;
            if (pacerMs >= mDurationSec * 1000 + guardMs) {
                App.getApp().requestStop();
                return;
            }
        }

        // Watchdog "perdita telefono": se l'app phone non può più mandare STOP
        // (es. killata) e il telefono si disconnette, una sessione phone-driven
        // resterebbe a campionare+trasmettere a vuoto fino all'auto-stop sulla
        // durata piena (= "l'orologio continua ad andare", batteria sprecata).
        // Dopo ~12s di telefono assente la abortiamo (il telefono è il system
        // of record: nessun dato da salvare lato watch).
        if (checkPhoneLost()) {
            App.getApp().requestAbort();
            return;
        }

        // Durante la prep (pacerMs < 0): nessun pacer, nessuna vibrazione —
        // l'orologio resta "silenzioso" così telefono e watch partono a regime
        // nello stesso istante. mLastPhase resta -1 finché non parte il regime,
        // così la prima fase (inspira) fa scattare la vibrazione.
        if (mPacer != null && pacerMs >= 0) {
            mSnapshot = PacerCalc.compute(mPacer, pacerMs);
            if (mSnapshot.phase != mLastPhase) {
                onPhaseChange(mSnapshot.phase);
                mLastPhase = mSnapshot.phase;
            }
        }
        Ui.requestUpdate();
    }

    // Ritorna true quando la sessione va abortita per telefono perso. Conta
    // solo per sessioni phone-driven; le standalone (GPS) proseguono offline.
    hidden function checkPhoneLost() {
        if (!App.getApp().isPhoneDrivenActive()) {
            mPhoneLostTicks = 0;
            return false;
        }
        var connected = true;
        try {
            connected = Sys.getDeviceSettings().phoneConnected;
        } catch (ex) {
            connected = true; // in dubbio NON abortire
        }
        if (connected) {
            mPhoneLostTicks = 0;
            return false;
        }
        mPhoneLostTicks += 1;
        // 5 Hz × 60 ≈ 12 s di telefono assente: tollera blip BT brevi.
        return mPhoneLostTicks >= 60;
    }

    // Vibrazione breve a inizio fase. Pattern diversi per dare al polso
    // una "lingua" facile da leggere senza guardare l'orologio.
    hidden function onPhaseChange(phase) {
        if (!(Toybox has :Attention)) { return; }
        if (!(Att has :vibrate)) { return; }
        var vibe;
        if (phase == PacerCalc.PHASE_INHALE) {
            // Doppio colpo corto: "su"
            vibe = [
                new Att.VibeProfile(60, 70),
                new Att.VibeProfile(0, 60),
                new Att.VibeProfile(60, 70),
            ];
        } else if (phase == PacerCalc.PHASE_EXHALE) {
            // Singolo colpo lungo: "giù"
            vibe = [ new Att.VibeProfile(50, 220) ];
        } else {
            return; // hold: nessuna vibrazione
        }
        try { Att.vibrate(vibe); } catch (ex) {}
    }

    // === Render ============================================================

    function onUpdate(dc) {
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_BLACK);
        dc.clear();
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);

        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        if (mScreen == SCREEN_ACTIVE) {
            drawActive(dc, w, h, cx, cy);
        } else if (mScreen == SCREEN_CONFIG) {
            drawConfig(dc, w, h);
        } else {
            drawIdle(dc, cx, cy);
        }
    }

    // ----- IDLE -----------------------------------------------------------
    //
    // Tutto sotto y=70 per evitare il sub-display circolare (centro ~(140,35),
    // raggio ~35) che nasconderebbe la parte destra di "HRV Trainer" e di
    // "Ready" se centrate in alto.

    hidden function drawIdle(dc, cx, cy) {
        dc.drawText(cx, 72, Gfx.FONT_MEDIUM,
            "HRV Trainer",
            Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, 100, Gfx.FONT_SMALL,
            "Ready", Gfx.TEXT_JUSTIFY_CENTER);

        // Mostra config corrente così l'utente sa cosa partirà.
        var durSec = SessionPrefs.getDurationSec();
        var rate   = computeBreathsPerMin(
            SessionPrefs.getInhaleMs(),
            SessionPrefs.getExhaleMs(),
            SessionPrefs.getHold1Ms(),
            SessionPrefs.getHold2Ms());
        var line1 = (durSec / 60).toString() + " min @ "
            + rate.format("%.1f") + "/min";
        dc.drawText(cx, 124, Gfx.FONT_XTINY,
            line1, Gfx.TEXT_JUSTIFY_CENTER);

        dc.drawText(cx, 144, Gfx.FONT_XTINY,
            "GPS: config", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, 160, Gfx.FONT_XTINY,
            "SET: esci", Gfx.TEXT_JUSTIFY_CENTER);
    }

    hidden function computeBreathsPerMin(inMs, exMs, h1Ms, h2Ms) {
        var period = inMs + exMs + h1Ms + h2Ms;
        if (period <= 0) { return 0.0; }
        return 60000.0 / period;
    }

    // ----- CONFIG (carosello) --------------------------------------------
    //
    // Una pagina alla volta. Layout pensato per evitare il sub-display
    // circolare dell'Instinct (~x=102..168, y=2..68):
    //   y=8    page indicator "n/6" (FONT_XTINY centrato, rimane stretto
    //          → entro la zona safe anche con sub-display)
    //   y=64   label parametro (FONT_SMALL centrato, sotto il sub-display)
    //   y=92   valore corrente (FONT_NUMBER_MEDIUM centrato, grande e
    //          leggibile a colpo d'occhio)
    //   y=h-48 hint UP/DN
    //   y=h-32 hint GPS
    //   y=h-16 hint BACK
    //
    // La pagina "Avvia" sostituisce label+valore con riepilogo e CTA grande.

    hidden function drawConfig(dc, w, h) {
        var cx = w / 2;

        // Page indicator (dentro safe zone perché molto stretto e centrato).
        var pageStr = (mPageIdx + 1).toString() + "/"
                    + CFG_PAGE_COUNT.toString();
        dc.drawText(cx, 8, Gfx.FONT_XTINY,
            pageStr, Gfx.TEXT_JUSTIFY_CENTER);

        if (mPageIdx == CFG_PAGE_START) {
            drawConfigStartPage(dc, w, h, cx);
        } else {
            drawConfigParamPage(dc, w, h, cx);
        }
    }

    hidden function drawConfigParamPage(dc, w, h, cx) {
        // Label appena sotto la zona del sub-display (y=68 è il bordo
        // inferiore approssimativo del cerchio nascosto).
        dc.drawText(cx, 60, Gfx.FONT_SMALL,
            labelForPage(mPageIdx),
            Gfx.TEXT_JUSTIFY_CENTER);

        // Valore grande al centro: forte focus visivo per il parametro
        // attualmente in editing.
        dc.drawText(cx, 90, Gfx.FONT_NUMBER_MEDIUM,
            valueForPage(mPageIdx),
            Gfx.TEXT_JUSTIFY_CENTER);

        // Hint in basso. Usiamo la nomenclatura dei tasti come serigrafata
        // sull'Instinct (MENU/ABC/GPS/SET) invece di UP/DOWN/SELECT/BACK,
        // così l'utente legge sui tasti gli stessi nomi che vede a schermo.
        dc.drawText(cx, h - 50, Gfx.FONT_XTINY,
            "MENU = +    ABC = -", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, h - 34, Gfx.FONT_XTINY,
            "GPS: avanti", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, h - 18, Gfx.FONT_XTINY,
            "SET: esci", Gfx.TEXT_JUSTIFY_CENTER);
    }

    hidden function drawConfigStartPage(dc, w, h, cx) {
        dc.drawText(cx, 60, Gfx.FONT_SMALL,
            "Pronto?", Gfx.TEXT_JUSTIFY_CENTER);

        // Riepilogo della config corrente (durata + freq respiri).
        var inMs   = SessionPrefs.getInhaleMs();
        var exMs   = SessionPrefs.getExhaleMs();
        var rate   = computeBreathsPerMin(inMs, exMs,
            SessionPrefs.getHold1Ms(), SessionPrefs.getHold2Ms());
        var durMin = SessionPrefs.getDurationSec() / 60;
        var summary = durMin.toString() + " min @ "
                    + rate.format("%.1f") + "/min";
        dc.drawText(cx, 88, Gfx.FONT_XTINY,
            summary, Gfx.TEXT_JUSTIFY_CENTER);

        // CTA grande centrata.
        dc.drawText(cx, 110, Gfx.FONT_MEDIUM,
            "AVVIA", Gfx.TEXT_JUSTIFY_CENTER);

        dc.drawText(cx, h - 34, Gfx.FONT_XTINY,
            "GPS: avvia", Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, h - 18, Gfx.FONT_XTINY,
            "SET: esci", Gfx.TEXT_JUSTIFY_CENTER);
    }

    hidden function labelForPage(i) {
        if (i == CFG_PAGE_DURATION) { return "Durata"; }
        if (i == CFG_PAGE_INHALE)   { return "Inspira"; }
        if (i == CFG_PAGE_EXHALE)   { return "Espira"; }
        return "";
    }

    hidden function valueForPage(i) {
        if (i == CFG_PAGE_DURATION) {
            return (SessionPrefs.getDurationSec() / 60).toString() + " min";
        }
        if (i == CFG_PAGE_INHALE) { return formatSec(SessionPrefs.getInhaleMs()); }
        if (i == CFG_PAGE_EXHALE) { return formatSec(SessionPrefs.getExhaleMs()); }
        return "";
    }

    hidden function formatSec(ms) {
        return (ms / 1000.0).format("%.1f") + " s";
    }

    // Modifica il parametro della pagina indicata di +/- 1 step. Persistito
    // subito in SessionPrefs (clamp dentro al setter), così l'uscita non
    // perde mai la modifica.
    hidden function adjustValueForPage(page, direction) {
        if (page == CFG_PAGE_DURATION) {
            var v = SessionPrefs.getDurationSec()
                  + direction * SessionPrefs.DUR_STEP_SEC;
            SessionPrefs.setDurationSec(v);
        } else if (page == CFG_PAGE_INHALE) {
            var v = SessionPrefs.getInhaleMs()
                  + direction * SessionPrefs.PHASE_STEP_MS;
            SessionPrefs.setInhaleMs(v);
        } else if (page == CFG_PAGE_EXHALE) {
            var v = SessionPrefs.getExhaleMs()
                  + direction * SessionPrefs.PHASE_STEP_MS;
            SessionPrefs.setExhaleMs(v);
        }
        // CFG_PAGE_START: nulla da modificare (filtrato dal caller).
    }

    // ----- ACTIVE ---------------------------------------------------------

    hidden function drawActive(dc, w, h, cx, cy) {
        var pacerMs = (Sys.getTimer() - mStartMs) - mPrepMs;

        // Fase di preparazione: "Preparati" + countdown, niente cerchio respiro
        // (l'orologio è silenzioso). Si arrotonda per eccesso così va 10→1 come
        // sul telefono.
        if (pacerMs < 0) {
            var prepLeft = ((-pacerMs) + 999) / 1000;
            dc.drawText(cx, 78, Gfx.FONT_MEDIUM,
                "Preparati", Gfx.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, 108, Gfx.FONT_NUMBER_MEDIUM,
                prepLeft.toString(), Gfx.TEXT_JUSTIFY_CENTER);
            var bpmPrep = (mBpm != null) ? (mBpm.toString() + " bpm") : "--";
            dc.drawText(cx, h - 26, Gfx.FONT_XTINY,
                bpmPrep, Gfx.TEXT_JUSTIFY_CENTER);
            return;
        }

        // Countdown in alto-sinistra (LEFT-justified a x=8) per stare fuori
        // dalla zona del sub-display in alto a destra. Centrato in alto
        // veniva tagliato dal cerchio nascosto. Sul tempo di sessione (pacerMs).
        if (mDurationSec != null) {
            var remainingMs = mDurationSec * 1000 - pacerMs;
            if (remainingMs < 0) { remainingMs = 0; }
            var remSec = remainingMs / 1000;
            var mm = remSec / 60;
            var ss = remSec % 60;
            var ssStr = ss < 10 ? "0" + ss.toString() : ss.toString();
            dc.drawText(8, 14, Gfx.FONT_SMALL,
                mm.toString() + ":" + ssStr,
                Gfx.TEXT_JUSTIFY_LEFT);
        }

        // Cerchio respiro.
        var amp = (mSnapshot != null) ? mSnapshot.amplitude : 0.0;
        var rMin = 26;
        var rMax = (cx < cy ? cx : cy) - 18;
        var r = (rMin + (rMax - rMin) * amp).toNumber();
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, r);
        dc.setPenWidth(1);

        // HR live al centro.
        var bpmStr = (mBpm != null) ? mBpm.toString() : "--";
        dc.drawText(cx, cy - 22, Gfx.FONT_NUMBER_MEDIUM,
            bpmStr, Gfx.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, cy + 14, Gfx.FONT_XTINY,
            "bpm", Gfx.TEXT_JUSTIFY_CENTER);

        // Label fase in basso.
        if (mSnapshot != null) {
            dc.drawText(cx, h - 26, Gfx.FONT_SMALL,
                PacerCalc.phaseLabel(mSnapshot.phase),
                Gfx.TEXT_JUSTIFY_CENTER);
        }
    }
}

// Delegate che intercetta i pulsanti del watch.
//
// Mapping su Instinct Solar 2X. I nomi sono quelli serigrafati sui tasti
// (lato sx top→bottom: CTRL, MENU, ABC; lato dx top→bottom: GPS, SET).
// In termini Connect IQ: MENU→onPreviousPage, ABC→onNextPage, GPS→onSelect,
// SET→onBack, CTRL→onKey(KEY_LIGHT).
//
//  IDLE:
//    GPS  → entra in pannello CONFIG (pagina 1: Durata)
//    SET  → esce dall'app
//  CONFIG (pagina parametro):
//    MENU → +1 step del parametro corrente (es. +1 min per Durata)
//    ABC  → -1 step
//    GPS  → avanza alla pagina successiva
//    CTRL → torna alla pagina precedente (best-effort: l'OS Garmin spesso
//           intercetta il tasto per aprire i Controls; se non arriva
//           all'app è ok, l'utente può scorrere in avanti col GPS)
//    SET  → esce a IDLE (i valori sono già salvati in SessionPrefs ad ogni
//           nudge, quindi nessuna perdita)
//  CONFIG (pagina "Avvia"):
//    GPS  → avvia sessione standalone (requestStartLocal legge SessionPrefs
//           e chiama view.startSession)
//    CTRL → torna a pagina parametro precedente
//    SET  → esce a IDLE
//  ACTIVE:
//    GPS  → stop+SAVE (FIT salvato + summary inviato al telefono)
//    SET  → ABORT (FIT scartato, nessun summary)
class HrvTrainerDelegate extends Ui.BehaviorDelegate {
    function initialize() {
        BehaviorDelegate.initialize();
    }

    function onSelect() {
        var app = App.getApp();
        if (app.isActive()) {
            app.requestStop();
            return true;
        }
        var view = app.getView();
        if (view != null && view.isConfigOpen()) {
            view.configSelect();
            return true;
        }
        // Idle: apri il pannello config.
        if (view != null) { view.enterConfig(); }
        return true;
    }

    function onBack() {
        var app = App.getApp();
        if (app.isActive()) {
            // Sessione in corso: BACK = annulla senza salvare.
            app.requestAbort();
            return true;
        }
        var view = app.getView();
        if (view != null && view.isConfigOpen()) {
            view.exitConfig();
            return true;
        }
        // Idle: lascia che il framework chiuda l'app.
        return false;
    }

    // MENU (tasto centrale-sinistra) → onPreviousPage. Aumenta il valore
    // (convenzione Garmin: MENU = up = +).
    function onPreviousPage() {
        return nudgeConfig(1);
    }

    // ABC (tasto basso-sinistra) → onNextPage. Diminuisce il valore
    // (convenzione Garmin: ABC = down = -).
    function onNextPage() {
        return nudgeConfig(-1);
    }

    // CTRL (tasto alto-sinistra, etichetta luce/ingranaggio): pagina
    // precedente nel carosello CONFIG. onKey() è ereditato da InputDelegate
    // e viene invocato per i tasti che i metodi behavior non gestiscono
    // (qui: KEY_LIGHT).
    function onKey(evt) {
        if (evt.getKey() == Ui.KEY_LIGHT) {
            var app = App.getApp();
            var view = app.getView();
            if (view != null && view.isConfigOpen()) {
                view.configPrevPage();
                return true;
            }
        }
        return false;
    }

    hidden function nudgeConfig(delta) {
        var app = App.getApp();
        var view = app.getView();
        if (view != null && view.isConfigOpen()) {
            view.configNudge(delta);
            return true;
        }
        return false;
    }
}
