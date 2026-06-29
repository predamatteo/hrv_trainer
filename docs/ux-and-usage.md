# UX e idea di utilizzo — HRV Trainer

> Documento di riferimento per design, copy e roadmap UX dell'app phone (`hrv_trainer/`). Tutto in italiano, come da convenzione del repo. Non è una specifica tecnica: è il "perché" e il "come dovrebbe sentirsi" l'esperienza, con i gap reali del codice e cosa fare. Aggiornato al 2026-06-29.

---

## 1. Per chi è / la promessa in una frase

**Persona primaria.** Adulto 30–55 anni con vita piena e un po' in tensione: lavoro cognitivo, sonno irregolare, magari un medico che gli ha detto di "respirare lento". Ha **già un Garmin Instinct** comprato per sport/outdoor — non per l'HRV — e quasi non ne guarda i dati. Non sa cosa siano RMSSD, RSA o baroriflesso, **e non vuole impararlo**: cerca un gesto semplice per ritrovare calma e la sensazione concreta di stare meglio. È a rischio *orthosomnia* (ansia da auto-monitoraggio): davanti a grafici, millisecondi o un "punteggio basso" si scoraggia o va in ansia — che paradossalmente abbassa l'HRV. Abbandona se l'app è criptica o lo fa sentire "sotto la media".

**Persona secondaria.** La stessa persona in versione "voglio anche capire come sto oggi": servita dallo *stesso* gesto con un livello di lettura in più, sempre **opt-in, mai imposto**. Attenzione: NON è un atleta. Il lessico da carico d'allenamento ("spingere", "sovrallenamento") va evitato; la lettura va inquadrata come "oggi il corpo è carico o riposato?", non come prescrizione di intensità sportiva.

**La promessa (one-liner usabile).**

> **Pochi minuti di respiro guidato al giorno per ritrovare la calma: segui il cerchio, non un numero.**

**Paragrafo "elevator" (per onboarding/store, non come headline).** Il respiro del giorno parte in un tap e funziona anche senza orologio. Col Garmin al polso ti conferma in silenzio che il corpo risponde, e settimana dopo settimana vedi la tua calma diventare il nuovo normale — la storia lenta che un'app di solo respiro non può darti.

---

## 2. L'idea di utilizzo

### Il modello mentale

> **"Non sto misurando la mia salute, sto allenando la calma."**

Il respiro lento alla tua frequenza è come spingere un'altalena al ritmo giusto: piccole spinte costanti fanno oscillare il cuore sempre di più. È la **risonanza del baroriflesso** (~0,1 Hz, ~6 atti/min): a risonanza l'oscillazione della frequenza cardiaca aumenta in modo marcato, anche di diverse volte rispetto al riposo (Lehrer & Gevirtz, 2014 — fattore indicativo, non una soglia). Non insegui un punteggio alto: coltivi una sensazione che, ripetuta ogni giorno, resta anche fuori dalla sessione. Il cerchio che respira (`features/pacer/widgets/breathing_orb.dart`) è lo strumento; tu lo segui e basta. Il numero, quando arriva, non è un voto ma "com'è andata oggi rispetto a te". E c'è un secondo livello: la tua **"linea di galleggiamento"** si alza lentamente con la pratica costante — e *questo*, non il valore di stamattina, è il progresso vero. Corollario onesto: **un giorno rosso è informazione, non una bocciatura.**

### I cinque pilastri

1. **Frizione zero, watch-optional.** Il respiro parte in 1 tap con l'orb già in movimento e funziona *senza* orologio. Il gate di connettività (`shared/connect_iq/widgets/watch_readiness_gate.dart`) non deve mai toccare il gesto quotidiano — esattamente come oggi `/pacer` parte da solo. Così la latenza START ~17s e lo `STATE:READY` non garantito non spengono mai l'abitudine.
2. **Onestà strutturale.** L'headline poggia sul segnale più affidabile *nel contesto giusto*: l'onda respiratoria a ~0,1 Hz, misurabile bene **solo durante il respiro guidato lento** (training/assessment a ~6/min). I numeri assoluti (RMSSD, HF, ms, LF/HF, score lnRMSSD) vivono nel dettaglio sessione in *progressive disclosure*: non puoi sbagliare un numero che non metti mai in primo piano.
3. **Anti-ansia by design.** Mai uno score live da inseguire, mai un rosso allarmante, confidence sempre dichiarata, confronto solo col **tuo** baseline (mai norme di popolazione), micro-celebrazione *prima* dei numeri.
4. **Il gesto lascia traccia → la storia lenta.** Il respiro quotidiano registra almeno durata e pattern anche senza orologio; col watch al polso aggiunge la coerenza. La dashboard cronica `/hrv` (oggi orfana) viene ricollegata alla Home come **specchio settimanale**. Si premia la costanza, non il conteggio di sedute (il numero di sessioni *non* è moderatore d'efficacia — Goessl et al., 2017).
5. **Impalcatura clinica gentile e opt-in.** Sequenza esplicita ma morbida: trova la RF (assessment) → respiro quotidiano alla tua frequenza → all'occorrenza sessione ~20 min e mantenimento. Framing "allenamento del nervo vago / della calma", **mai** "clinico / terapia / graduation". Validazione occasionale della RF (non perché "si sposta": la RF è un tratto individuale tendenzialmente stabile, legato a volume ematico/statura).

### Onesto sui limiti (e sulla sicurezza)

Questi sono vincoli reali dell'hardware (Instinct Solar 2X), già gestiti correttamente nel dominio (`lib/shared/hrv/`), e vanno comunicati come **scelte di robustezza**, non come scuse:

- **Non è un dispositivo medico, e non sostituisce un parere clinico.** I benefici del metodo (ansia, ipertensione, ecc.) sono contesto scientifico, non garanzie dell'app. I valori non sono validati contro ECG gold-standard su questo dispositivo. **Non usare l'app per decisioni mediche o sulla terapia.** Un disclaimer dettagliato di *stima* esiste già in-app (`_EstimationDisclaimer`, `session_detail_screen.dart:1462`); manca il framing "dispositivo medico" e va portato dove servono le decisioni (vedi GAP #4).
- **Sicurezza del respiro lento.** Per i principianti il respiro lento/profondo può dare capogiri, formicolii o lipotimia, e il focus interocettivo può innescare ansia in chi è predisposto. Serve un messaggio chiaro: *"Se senti capogiri o fastidio, fermati e torna a respirare normale."* Oggi **non esiste** → va aggiunto.
- **Caveat cardiaco/farmaci.** Con aritmie (es. fibrillazione atriale) o con beta-bloccanti, HRV/RMSSD/readiness sono **non interpretabili** e la pulizia-artefatti non gestisce l'AFib. Combinato con la policy "mai mostrare rosso / mai allarmare", questo può *mascherare* un problema cardiaco reale: va detto esplicitamente che l'app non serve per diagnosi o decisioni cardiache e che certe condizioni/farmaci invalidano i numeri.
- **RR stimati da HR a 1 Hz: il problema è la quantizzazione, non Nyquist.** Gli intervalli sono ricostruiti (`estimated_from_hr`, `RR = 60000/bpm`), non battito-battito. La sorgente d'errore dominante — come dice il codice stesso (`_clean`, `_oscillationAmplitudeAt`) — è la **quantizzazione del bpm intero** (~10–16 ms per step a 60 bpm) sommata al campionamento grezzo ~1 Hz: sommerge le piccole differenze battito-battito da cui dipendono RMSSD e la banda HF. *Non* è (principalmente) Nyquist: a 1 Hz il limite è 0,5 Hz e 0,40 Hz ci sta sotto, tranne a HR molto basse. Conseguenza: RMSSD sottostima ~10% vs Garmin nativo, e `HrvConfidence` non raggiunge **mai** `high` su dati stimati — è onesto, non un bug.
- **L'onda a ~0,1 Hz è il segnale forte — ma solo a respiro guidato lento.** A risonanza l'ampiezza è grande rispetto al rumore, quindi sopravvive: per questo `ResonanceAssessment.analyze()` (`session_models.dart`) pesa **picco-valle 0,45 + LF 0,30 + SDNN 0,10 + coerenza 0,15**. SDNN però integra *tutta* la varianza (inclusa la banda rumorosa): è una metrica di supporto rumorosa su RR stimati. La sincronia di fase HR↔respiro (~180°) è *uno* dei criteri di Lehrer, ma il criterio cardine è la massima ampiezza picco-valle (come afferma il codice) → la fase resta solo guida visiva dell'orb, mai vantata come metrica.
- **La coerenza è un segnale di biofeedback relativo, non una metrica clinica.** `coherenceRatio` (`hrv_metrics.dart`, `_coherence`) = potenza nel picco / (totalPower − picco), e `totalPower = lfPower + hfPower` include **anche** la banda HF rumorosa: il denominatore è contaminato. È un'euristica stile HeartMath (costrutto proprietario **non** validato clinicamente), ottima come feedback *ambient* nel respiro guidato, da non presentare come misura spettrale "pulita".
- **La readiness quotidiana da wearable consumer ha evidenza limitata** e alta variabilità individuale e giorno-su-giorno. Lo "specchio settimanale" è una tendenza personale, **non** un verdetto affidabile sul singolo giorno: prominenza ridotta, confidence esposta.
- **Tempistiche oneste.** Calma immediata (<1 min); i guadagni stabili maturano in **settimane-mesi** (il protocollo Lehrer-Gevirtz dura tipicamente ~10 settimane), mai sul singolo giorno.
- **Tutto resta sul telefono.** Nessun cloud (vincolo CIQ-only): la privacy è una feature. Corollario: anche la strumentazione del successo (§8) sarà locale.

---

## 3. Il core loop (il gesto quotidiano)

> **Durata canonica del "respiro del giorno": 3 minuti.** Il <90s è solo la *Pausa di calma (SOS)*; i 5 min sono la *variante sera*. Tutte le altre sezioni usano questa stessa durata.

Apri l'app (o tocchi la notifica del mattino) e in **un tap** parte *Il respiro del giorno*: l'orb sta già respirando alla tua frequenza (~5,5–6/min, espiro più lungo dell'inspiro), come fa oggi il pacer che si autoavvia in `initState` (`features/pacer/pacer_screen.dart`).

1. **Segui il cerchio per ~3 minuti** — *oppure senti la vibrazione.* La guida aptica esiste già (`pacer_controller.dart`, `Vibration.vibrate`, `hapticsEnabled` default true): è il canale più calm-tech, perfetto per respirare a occhi chiusi (SOS/sera). Va resa first-class nel copy: "segui il cerchio o senti la vibrazione".
2. **Se il Garmin è al polso, registra in sottofondo** senza bloccare nulla. Watch-less il respiro **lascia comunque traccia** (durata + pattern, ed eventuale calma 1-tap); la **coerenza si registra solo col watch** (l'orb da solo è un timer, non produce RR). In entrambi i casi alimenta la storia lunga.
3. **Durante la sessione, niente numeri in primo piano:** solo movimento e colore dell'orb, con la `CoherenceBar` (`shared/ui/coherence_bar.dart`) come segnale *ambient* — "quando sale, sei in sintonia col respiro" — **mai** uno score HRV live da inseguire.
4. **A fine respiro, micro-celebrazione calda PRIMA di qualunque dato.** Alla prima volta (nessun baseline) basta "Bel respiro. Ti sei preso un momento per te." Quando il baseline esiste, al massimo *una* riga riferita al **tuo** solito ("Calma più profonda del solito" / "Oggi il corpo è un po' carico, vai piano").
5. **Chi vuole**, dopo il gesto e in modo leggero, riceve la lettura di prontezza con un'azione quasi ternaria: verde → sessione piena alla tua RF, giallo → respiro di recupero più dolce, rosso → solo respiro lento. **Suggerimento, mai blocco.**

Chiudi e vai avanti con la giornata. Impegno percepito del rituale principale: ~3 minuti; la *Pausa di calma* costa **< 90 secondi**.

---

## 4. L'arco di progressione

L'ordine clinico implicito è *trova la RF → respiro quotidiano → sessione/mantenimento*. Oggi il codice lo suggerisce solo localmente (l'assessment imposta il pacer; il setup training mostra un nudge se manca la risonanza), ma **nessuna sequenza è guidata**: dalla Home si può lanciare "Biofeedback" senza aver mai fatto nulla. L'arco target:

**Giorno 0 — onboarding calmo (~30–60s, oggi del tutto assente).** Promessa breve + un **primo respiro guidato di 1 minuto subito**, senza orologio e senza permessi, per sentire l'effetto calmante (l'*aha-moment* in <1 min). L'onboarding deve *educare davvero*, in lingua-utente, con 3–4 frasi effettive (non solo "mostra una promessa"):
- *Cos'è:* "Alleni la calma con il respiro. Non stai misurando la tua salute."
- *Perché funziona:* "Respirando lento il cuore inizia a oscillare più ampio, e questo calma il sistema nervoso."
- *Cosa fa il cerchio:* "Inspira mentre cresce, espira mentre cala. Segui il suo ritmo, o senti la vibrazione."
- *Cosa aggiunge l'orologio:* "Se hai il Garmin, conferma in silenzio che il corpo risponde — e tiene la storia dei tuoi progressi."
Qui si fissano aspettative oneste (calma subito, guadagni stabili in settimane-mesi), il messaggio "non è un dispositivo medico" + la nota di sicurezza ("se senti capogiri, fermati"), e l'ancoraggio a una routine esistente ("dopo la sveglia, prima del caffè" — Tiny Habits). I permessi (notifiche `POST_NOTIFICATIONS` su Android 13+; Bluetooth) si chiedono **dopo** il primo respiro, al momento in cui servono, mai all'avvio.

**Settimana 1 — solo l'abitudine del respiro.** In sottofondo, se l'orologio c'è, si raccolgono le prime letture per il baseline. L'app dichiara "sto ancora imparando il tuo normale" e **non** dà giudizi forti (insight *gated* finché < 3 letture, `ReadinessCalculator.minBaselineDays = 3`). **Buco di retention da coprire:** tra l'aha-moment del Giorno 0 e il payoff del trend (settimane-mesi) c'è una "valle". Il motivo per tornare domani, qui, è la *calma percepita subito* + una conferma calda e variata fin dalla prima volta — non un grafico che ancora non ha senso, e mai una streak colpevolizzante.

**Dopo che l'abitudine si è formata (non in settimana 1) — "trova la tua altalena giusta".** L'Assessment (`features/assessment/assessment_screen.dart`: scan 6,5→6,0→5,5→5,0→4,5/min) presentato come **scoperta personale**, non come test. Dichiarare in anticipo che dura **~10 minuti** (5 ritmi × **2,5 min/ritmo**, `kStepDurationSec = 150`) e il beneficio concreto: "da qui il respiro è cucito su di te, più efficace e piacevole". Saltarlo è ok: mantiene semplicemente il default sicuro (~5,5/min). Da qui il pacer di default usa la **tua** frequenza di risonanza.

**Settimane 2–4 — il cerchio misura→azione.** Dopo il respiro compare (opt-in) la lettura di prontezza morbida con il suggerimento ternario. Chi vuole può allungare verso la sessione "classica" ~20 min alla RF (clinicamente allineata alla dose Lehrer-Gevirtz), ma il **default resta corto**.

**Mesi 1–3 — la "storia lenta".** Si apre la dashboard cronica `/hrv` (`features/hrv_dashboard/hrv_dashboard_screen.dart`), **oggi rotta orfana** (registrata in `core/router/app_router.dart` ma senza alcun punto d'ingresso), da **ricollegare alla Home come specchio settimanale**: non il valore del giorno ma la "linea di galleggiamento" che sale (coerenza nel training, trend lnRMSSD relativo a te), con i limiti dichiarati (alta variabilità). Nessuna "graduation": il mantenimento resta un rituale aperto, 3–20 min quasi-quotidiani alla RF.

### I rituali

- **Il respiro del mattino** (ancora principale): appena sveglio, prima del caffè, ~3 min con l'orb. La lettura di prontezza arriva *dopo*, mai prima del gesto.
- **Pausa di calma (SOS):** in un momento di tensione, parte in un tap senza orologio — effetto acuto immediato (<90s), occhi chiusi con l'aptica, non una misura.
- **Respiro della sera:** ritmo più lento (5,0/min, espiro allungato) e tema notturno già esistente, ~5 min per il wind-down pre-sonno.
- **Sguardo lento settimanale:** una volta a settimana (non ogni giorno) si apre lo specchio lungo (`/hrv` ricollegata) — premio sul **trend**, non sul valore del giorno.
- **Tag-contesto in ~10s** dopo la misura col watch (sonno/alcol/malato/stress/fatica): alimenta il "perché" della frase di oggi e l'impatto-abitudini cronico.
- **Un solo promemoria al mattino,** silenzioso di notte: nudge gentile all'orario scelto, mai motivazionale invadente, mai colpevolizzante se salti un giorno.

---

## 5. Principi UX (linea guida)

Ogni principio è **principio → regola concreta per questa app**.

1. **Calm tech — vivi nella periferia dell'attenzione.** *Regola:* durante `measuring`/`running` l'orb + **una** istruzione restano i protagonisti; le stat live (RMSSD / RSA Δ / Campioni in `shared/hrv/widgets/live_session_view.dart`) restano periferiche. Non reintrodurre SDNN/LF peak nella vista di misura. Il feedback è colore/movimento dell'orb + `CoherenceBar` + **aptica**, non cifre che cambiano.

2. **Frizione zero prima della misura.** *Regola:* dalla Home o dalla notifica al primo battito in ≤1 tap. Il gate deve auto-tentare `reconnect()` + attivazione BT da solo *prima* di interpellare l'utente; chiede conferma solo se il tentativo automatico fallisce. Il contesto (sonno/fattori) si raccoglie **dopo** la misura (lo step `review` del check-in è già così).

3. **Una cosa per schermata.** *Regola:* la Home grida "fai il respiro del giorno" con **un** CTA dominante, non elenca metriche; il setup training resta contesto-first con default a un tap, mai un muro di slider.

4. **Guida prima dei dati.** *Regola:* introduci un concetto *prima* che compaia in dashboard. L'educazione oggi è tutta post-azione (la più ricca è `features/history/session_detail_screen.dart` + `hrv_interpretation.dart`, peraltro in gergo clinico fitto): serve un'affordance di aiuto in-linea riusabile (oggi i Tooltip esistono solo in 3-4 punti, poco scopribili su touch).

5. **Mai allarmismo sui numeri — ma mai sopprimere l'onestà.** *Regola:* mai colorare un RMSSD basso di `alert` rosso come fosse un problema medico; usa fasce relative al baseline e mostra **sempre** la confidence, ricordando che è una stima. Attenzione: "è una stima, non una misura clinica" **va detto**, non nascosto per non spaventare. La "saturazione vagale" già ammorbidisce il rosso a giallo (`readiness.dart`): coerente con questo principio.

6. **Autoconfronto, non confronto.** *Regola:* `/hrv` e `/history` confrontano l'utente col proprio baseline/media mobile. Le finestre sono **tre, distinte:** z-score/SWC sul baseline cronico ~60gg (`chronicDays = 60`), CV(lnRMSSD) su finestra 7gg (`defaultWindowDays = 7`), dashboard `/hrv` su 90gg (`kHrvDashboardWindowDays = 90`). Niente leaderboard, percentili di popolazione o etichette assolute — è la scelta esplicita di `HrvTrendCalculator`.

7. **Coerenza coi token di design.** *Regola:* usa `context.tokens.<x>` (`core/theme/app_tokens.dart`), mai hex hardcoded; le uniche eccezioni deliberate sono i colori categorici in `session_chart_utils.dart`. La triade `good/warn/alert` è l'unico vocabolario di stato.

8. **Framing positivo della readiness, senza lessico atletico.** *Regola:* `ReadinessRing` e copy incoraggiano e consigliano ("oggi il corpo è riposato: buona giornata per un respiro pieno" / "giornata carica: vai leggero"), mai puniscono. Il copy oggi spedito è da carico-allenamento ("Via libera al carico" / "Recupero") e va riscritto per il non-atleta (vedi GAP #6).

9. **Celebrazione immediata (Tiny Habits).** *Regola:* allo stato `saved` di check-in/training/respiro, micro-celebrazione calda **prima** delle metriche, con una variante senza-baseline per il Giorno 1.

10. **Funzionare quando fallisce (degradazione graziosa).** *Regola:* data la latenza START ~17s e lo `STATE:READY` non garantito, lo stato "riconnessione…" sta in periferia, il recupero delle standalone session è silenzioso al resume (`main.dart`). Mai una schermata d'errore ansiogena. Senza Garmin, il respiro resta pienamente valido.

11. **Accessibilità.** *Regola:* target touch generosi (FilledButton 64×54), contrasto AA già tarato sui token (`faint` ~4,86:1 light / ~4,63:1 dark), e **non** affidare informazione solo al colore: accompagna banda e numero con una parola ("Recuperato" / "Sotto il tuo solito"). Inoltre, oggi mancanti: `Semantics` per l'orb animato e la `CoherenceBar` (un utente TalkBack riceve un'animazione senza etichetta) e rispetto del *text scaling* / dynamic type, rilevante per la persona 30–55.

---

## 6. Tono di voce (IT)

L'app parla **calma, incoraggiante, chiara**. È un compagno di respiro, non un referto. Mai gergo in primo piano, mai diagnosi, mai colpa.

**Principi di copy**
- Frasi brevi, in seconda persona, presente. Verbi di azione gentile ("segui", "respira", "vai piano").
- Il numero non è un voto: è "com'è andata **rispetto a te**".
- Confidence sempre dichiarata come **stima personale**, non referto — ma la dichiarazione di stima non si nasconde.
- Mai vendere RMSSD/HF assoluti; l'headline è coerenza/calma/respiro.
- **Regola d'oro del vocabolario:** i termini interni (RMSSD, SDNN, z-score, σ, Nyquist, LF/HF, coerenza, CV) **non arrivano MAI alla UI**. Si traducono sempre (vedi appendice).

**Microcopy — do / don't**

| Contesto | ✅ Buono | ❌ Cattivo |
|---|---|---|
| Fine respiro (con baseline) | "Bel respiro. Calma più profonda del solito." | "RMSSD 38 ms · Score 54/100" |
| Fine respiro (Giorno 1, no baseline) | "Bel respiro. Ti sei preso un momento per te." | "Calma più profonda del solito" |
| Readiness basso | "Oggi il corpo è un po' carico: vai piano, un respiro lento basta." | "HRV BASSA (-1,5σ) — rischio sovrallenamento" |
| Baseline incompleto | "Sto ancora imparando il tuo normale: continua e tra qualche giorno avrà più senso." | "Dati insufficienti (n<3)" |
| Senza orologio | "Il respiro funziona benissimo anche senza orologio. Il Garmin, se lo metti, conferma in silenzio." | "Errore: nessun dispositivo connesso" |
| Attesa watch | "L'orologio sta avviando la misura: tienilo al polso, ci pensiamo noi." | "START_SESSION timeout (17s)" |
| Disclaimer medico (watch-independent) | "Non è un dispositivo medico: allena la calma, non diagnostica." | "I valori potrebbero essere imprecisi." |
| Disclaimer stima (solo watch) | "È una stima dal tuo Garmin, utile per il tuo trend, non per confronti clinici." | "Dati potenzialmente errati." |
| Sicurezza | "Se senti capogiri, fermati e torna a respirare normale." | *(silenzio)* |
| Reminder mattino | "Un minuto di respiro prima del caffè?" | "Non hai ancora fatto la sessione di oggi!" |
| Giorno saltato | (silenzio, oppure) "Bentornato. Ripartiamo con un respiro." | "Hai interrotto la tua serie di 6 giorni." |

**Da evitare sempre:** punti esclamativi motivazionali, rosso "allarme medico", σ/Nyquist/n.u. in primo piano, qualsiasi "dopo X sessioni sei a posto", confronto con altri utenti, lessico da carico d'allenamento per la persona primaria.

**Appendice — vocabolario interno → vocabolario utente** *(i termini di sinistra non compaiono MAI in UI)*

| Interno | In lingua-utente |
|---|---|
| HRV / RMSSD | "quanto il cuore è elastico e reattivo" |
| Coerenza / coherenceRatio | "quanto il battito oscilla pulito seguendo il respiro" → etichetta UI proposta: **Sintonia** (o *Onda*) |
| Risonanza / RF | "la tua altalena giusta", "il tuo ritmo di respiro" |
| Readiness / prontezza | "oggi il corpo è carico o riposato?" |
| Baseline | "il tuo normale" |
| Confidence | "quanto è sicura la stima" |

---

## 7. Architettura dell'informazione

La struttura attuale è una **shell a 4 tab** (`StatefulShellRoute.indexedStack` in `core/router/app_router.dart`) + **flussi immersivi top-level** che coprono la nav. Va riletta alla luce dell'idea di utilizzo:

- **Home (`/`)** — *il gesto*. Deve gridare **una** azione: "Il respiro del giorno" con l'orb pronto a partire. La `_ReadinessHero` resta, ma demota il semaforo a sottotono (mai protagonista) e la lettura di prontezza arriva *dopo* il respiro. La Home è anche la **porta della storia lenta**: deve ospitare il punto d'ingresso (oggi mancante) verso `/hrv` come "specchio settimanale". `/readiness` e `/hrv` restano figli del branch Home — sono **letture**, non gesti.

- **Sessione (`/sessione`)** — *la scelta consapevole*. Hub per scegliere il tipo di pratica. La differenziazione "descrizioni più ampie" è **già implementata** (Home: `_PracticeTile` compatte; Sessione: `_PracticeCard` con sottotitoli). Il problema vero non è ridescrivere Sessione ma le **due porte agli stessi flussi** ("da dove inizio?"): la decisione, coerente col Principio #3, è se la Home debba **rimuovere la griglia** lasciando un solo CTA + l'ingresso alla storia lenta.

- **Storico (`/history`)** — *il registro*. Newest-first, filtri, backup, sync watch. Il dettaglio (`session_detail_screen.dart`) resta la superficie di *progressive disclosure*: qui — e solo qui — vivono ms, LF peak, Poincaré, e il disclaimer di stima già esistente.

- **Profilo (`/settings`)** — *configurazione + fiducia*. Oltre a nome/orologio/promemoria, deve ospitare ciò che oggi manca: una sezione **Aiuto/Come funziona/About**, il **disclaimer "non è un dispositivo medico"**, la nota di sicurezza/caveat cardiaco, e un mini-glossario opzionale.

- **Flussi immersivi** (`/pacer`, `/training`, `/assessment`, `/readiness/checkin`) — top-level su `rootNavigatorKey`, modali nello spirito (wakelock + `PopScope`). Regola d'oro: **solo `/pacer` resta senza gate** (è il gesto quotidiano); training/check-in/assessment mantengono `ensureWatchReady()` perché *richiedono* la misura.

**Le tre superfici di lettura vanno rese esplicite all'utente** (oggi la distinzione vive solo nei commenti del codice): Readiness = *acuto*, "mi alleno oggi?"; Andamento HRV = *cronico*, "mi sto adattando?"; Storico = *registro*, "cosa ho fatto". E una delle tre (`/hrv`) è pure irraggiungibile.

---

## 8. GAP prioritizzati (roadmap)

Dove l'app **oggi** tradisce queste linee guida. Basato sui gap reali trovati nel codice.

| # | Pri | Dip. da | Problema | Dove (file/schermata) | Intervento |
|---|---|---|---|---|---|
| 1 | **Alta** | — | **Nessun onboarding / first-run** (grep `onboard\|welcome\|firstRun` = 0): l'utente atterra su "Baseline in costruzione" + tile senza sapere cosa sia l'app. **Load-bearing #1** (retention). | `core/router/app_router.dart`, `features/home/`, `main.dart` | Flusso `/onboarding` ~30–60s con le **3–4 frasi educative effettive** (§4) + primo respiro 1 min (no orologio/permessi) + aspettative oneste + sicurezza + ancoraggio routine. |
| 2 | **Alta** | — | **Il respiro non lascia traccia**: il pacer non persiste nulla, watch o no. | `pacer_screen.dart`, `pacer/state/pacer_controller.dart` | Persistere **durata + pattern (+ calma 1-tap)** sempre; **coerenza SOLO col watch** (il pacer non ingerisce HR/RR: watch-less non c'è coerenza da salvare). Alimenta `/hrv`. |
| 3 | **Alta** | #2 | **`/hrv` è rotta orfana**: nessun `push/go('/hrv')` in `lib`; "storia lenta" invisibile. *Dipende da #2: senza traccia lo specchio non riflette nulla.* | `features/hrv_dashboard/`, `features/home/`, `core/router/app_router.dart` | Ricollegare `/hrv` dalla Home come "specchio settimanale"; verificare il `_BackButton` che presuppone un push. |
| 4 | **Alta** | #1 | **Disclaimer medico + sicurezza non in superficie.** Esiste già `_EstimationDisclaimer` (`session_detail_screen.dart:1462`, post-misura) ma copre *stima/confronto clinico*, NON "dispositivo medico", ed è sepolto. Mancano nota capogiri e caveat cardiaco/farmaci. | `session_detail_screen.dart:1462` (riuso), `settings_screen.dart`, onboarding (#1), accanto al verdetto readiness | Aggiungere "non è un dispositivo medico" + nota sicurezza + caveat AFib/beta-bloccanti; **surfacing contestuale** accanto al verdetto, riusando il copy esistente. |
| 5 | **Media** | — | **Lettura mattutina su segnale fragile**: il check-in è a respiro **spontaneo** (~0,2–0,27 Hz); lì né RMSSD (quantizzazione) né RSA/coerenza sono affidabili — `peakToTroughMs` è misurato nel picco LF (0,04–0,15 Hz), *non* alla freq respiratoria spontanea. | `features/readiness/`, `features/home/`, `shared/hrv/readiness.dart` | (a) far precedere il check-in da ~1 min di respiro guidato a 6/min (riporta la modulazione a 0,1 Hz); oppure (b) accettare il limite → finestre più lunghe, confidence esposta, **prominenza ridotta**. Non vendere RSA/coerenza come "headline affidabile". |
| 6 | **Media** | — | **Copy readiness atletico, off-tone** per la persona ansia-avversa: `TrainingAdvice` = "Via libera al carico"/"Carico leggero"/"Recupero"; headline "Pronto a dare". | `shared/hrv/readiness.dart` (label/headline/message) | Riscrivere le stringhe per il non-atleta ("oggi il corpo è carico o riposato?"), togliere il lessico da carico d'allenamento. |
| 7 | **Media** | #1 | **Requisito Garmin non spiegato a monte + frizione di collegamento** (install CIQ, BT, ~17s) assente dalla roadmap: è il maggior punto d'abbandono. | `watch_readiness_gate.dart`, onboarding, `features/settings/` | Onboarding: il respiro funziona sempre, l'orologio "conferma in silenzio". Mini-flusso opt-in "collega l'orologio" (cosa installare, BT, ~15s) **quando l'utente è pronto**. Auto-tentare reconnect+BT prima di interpellare. |
| 8 | **Media** | — | **Semaforo verde/giallo/rosso come prodotto quotidiano in Home**: verdetto troppo attivante per un profilo ansioso. | `features/home/home_screen.dart` (`_ReadinessHero`) | Demotare il semaforo a sottotono; in primo piano il **trend settimanale** + una frase. Il ternario arriva *dopo* il respiro, mai come blocco. |
| 9 | **Media** | — | **Sequenza consigliata mai guidata**: l'ordine RF→respiro→sessione è solo implicito. | `features/home/`, `features/training/`, `features/assessment/` | Percorso "inizia da qui" leggero (respiro → trova la RF → quotidiano), opt-in e mai bloccante. |
| 10 | **Media** | — | **Score e gergo opachi + concetti chiave mai definiti** in lingua-utente (coerenza, prontezza, risonanza, HRV). | `shared/hrv/hrv_metrics.dart`, `features/readiness/`, dashboard | Glossario/aiuto in-linea + score in linguaggio relativo al baseline (appendice §6). Mai σ/Nyquist/n.u. in primo piano. |
| 11 | **Media** | — | **Doppia superficie ambigua**: Home e Sessione portano agli stessi flussi (descrizioni ampie già fatte). | `features/home/`, `features/sessione/sessione_hub_screen.dart` | Decidere se la Home **rimuove la griglia** (solo CTA + storia lenta); Sessione = menù varianti + assessment/re-test. |
| 12 | **Media** | — | **Aptica non first-class + audio indeciso**: guida vibrazione già costruita ma assente dal racconto; `soundEnabled` (default false) senza implementazione. | `pacer/state/pacer_controller.dart` | "Segui il cerchio o senti la vibrazione" first-class (occhi chiusi in SOS/sera). Decidere `soundEnabled` (implementare o rimuovere). |
| 13 | **Bassa** | — | **Nessun criterio di successo / strumentazione**: retention/aha-moment/costanza non misurati. | trasversale | Metriche **locali** (on-device): time-to-first-breath, % sessioni watch-less, costanza, ritorno D1/D7, completamento onboarding. |
| 14 | **Bassa** | — | **Empty-state deboli + mancano componenti UX riusabili** (`EmptyState`, `Callout`, "tappable info"); Tooltip poco scopribili. | `features/history/`, `features/hrv_dashboard/` (`_EmptyState` duplicati), `shared/ui/` (manca) | EmptyState condiviso che instrada al primo respiro; `Callout` on-brand + variante "tappable info" della `Pill`. |
| 15 | **Bassa** | — | **Hex hardcoded fuori dai token**: palette satura in `session_chart_utils.dart`; `session_detail_screen.dart:393` (`0xFF7B908C`). *(NON l'orb: i default `0xFF4FB3BF/0xFF14695E` sono argomenti morti — i call site passano i token; al più `@required`.)* | `session_chart_utils.dart`, `session_detail_screen.dart:393`, `breathing_orb.dart` | Allineare `qualityColor` a `good/warn/alert`; passare i token a `_row`; rimuovere i default morti dell'orb. |
| 16 | **Bassa** | — | **Accessibilità oltre touch/contrasto**: nessuna `Semantics` per orb animato e `CoherenceBar`; text scaling non verificato. | `breathing_orb.dart`, `coherence_bar.dart` | Etichette `Semantics` per orb/CoherenceBar (TalkBack); test con text scaling alto. |

---

## 9. Stato di implementazione (branch `feat/ux-roadmap`)

**Fatto:** GAP 1 (onboarding), GAP 2 (il respiro lascia traccia), GAP 3 (`/hrv` riagganciata); e dei medi/bassi: `#5b` confidence esposta sulla lettura del giorno (scelta: respiro spontaneo, baseline intatto), `#6` copy non-atletico, `#7` perché serve l'orologio, `#8` semaforo demotato, `#10` (parziale: spiegazione vista cronica), `#12` rimosso `soundEnabled`, `#14` `EmptyState`/`Callout` condivisi, `#15` hex residui, `#16` Semantics.

### Backlog (rimandati, non abbandonati)

- **`#9` Sequenza guidata — in gran parte coperta** dal nuovo onboarding (accompagna respiro → orologio → pratica). Resta eventuale un nudge "inizia da qui / trova la risonanza" in Home per chi salta l'onboarding.
- **`#10` Glossario/tooltip sui singoli termini** (RMSSD, coerenza, z-score, …): fatto il framing della vista cronica; mancano le info-affordance puntuali sui termini (usare il `Callout`/una "tappable info").
- **`#11` Dedup `_PracticeTile`/`_PracticeCard`:** marginale — le due card hanno forme volutamente diverse (tile compatta in Home vs card descrittiva in Sessione). Da valutare solo se diverge il design.
- **`#13` Strumentazione del successo — metriche d'uso locali.** Solo on-device (nessun invio in rete, vincolo CIQ-only): time-to-first-breath, % sessioni watch-less, costanza, ritorno D1/D7, completamento onboarding. *Rimandato per scelta esplicita (priorità bassa).*

> Convenzione: quando una voce del backlog viene implementata, spostarla qui come "fatto" o rimuoverla.

---

*Documento vivo: aggiornare i riferimenti di file quando il codice cambia. Le decisioni aperte restano del proprietario.*
