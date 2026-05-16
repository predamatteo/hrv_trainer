# HRV Trainer

App mobile **Android** per il **biofeedback della variabilità cardiaca** (HRVB, modello Lehrer-Gevirtz, frequenza di risonanza ≈ 0,1 Hz) che si integra con un **Garmin Instinct Solar 2X** per il monitoraggio del battito cardiaco. iOS non supportato.

> ⚠️ **Disclaimer — Non è un dispositivo medico.**
> Questo software è un progetto personale a scopo formativo e di benessere. **Non** è certificato come dispositivo medico (non è MDR/FDA), **non** fornisce diagnosi, terapia o monitoraggio clinico e **non** sostituisce il parere di un professionista sanitario. La HRV biofeedback può non essere appropriata in presenza di aritmie, patologie cardiache, disturbi respiratori, gravidanza o terapie farmacologiche attive: in tali casi consulta un medico prima di usarla. L'utente è l'unico responsabile dell'uso che ne fa.

## Architettura

Il progetto è composto da **due applicazioni** che comunicano via Bluetooth:

```
 ┌──────────────────────┐       ┌─────────────────────────┐
 │  hrv_trainer         │       │  hrv_watch_ciq          │
 │  (Flutter iOS/Android)│       │  (Connect IQ Monkey C)  │
 │                      │ ◀────▶│  su Instinct Solar 2X   │
 │  • Pacer respiratorio│  BLE   │  • Sensor HR            │
 │  • Assessment RF     │  CIQ   │  • HRV on-demand        │
 │  • Training 20 min   │        │  • Risposta JSON        │
 │  • Storico + trend   │        │                         │
 └──────────────────────┘       └─────────────────────────┘
              │
              └── fallback BLE diretto (flutter_blue_plus) per
                  fasce toraciche ECG (es. Polar H10) quando
                  CIQ non è disponibile.
```

### Flutter app (`hrv_trainer/`)

- **State management:** `flutter_riverpod`
- **Routing:** `go_router`
- **Storage:** `sqflite` (sessioni, assessment, campioni RR)
- **Grafici:** `fl_chart` (HR live, trend SDNN/RMSSD)
- **Feedback:** `vibration` per l'haptic sulle fasi inspira/espira
- **Bridge nativo:** `MethodChannel` verso il Connect IQ Mobile SDK

Struttura:

```
lib/
 ├── core/
 │   ├── router/        # go_router routes
 │   └── theme/         # palette petrolio + verde muschio, M3
 ├── features/
 │   ├── home/          # dashboard, stato watch, scorciatoie
 │   ├── pacer/         # pacer libero, cerchio espandibile
 │   ├── assessment/    # scansione 6.5 → 4.5 bpm per trovare RF
 │   ├── training/      # sessione 20 min con metriche live
 │   └── history/       # storico + trend settimanali
 └── shared/
     ├── hrv/           # RrInterval, HrvMetrics, BreathingPattern
     ├── connect_iq/    # HeartRateSource, mock, Garmin CIQ
     └── storage/       # AppDatabase, SessionRepository
```

### Connect IQ app (`hrv_watch_ciq/`)

Monkey C app minimale che:

1. Mantiene attivo il sensore HR dell'Instinct Solar 2X durante una sessione.
2. Invia a ogni battito un messaggio `HR_SAMPLE` al telefono (payload JSON).
3. **Su richiesta** (`REQUEST_HRV`) calcola RMSSD / SDNN sulla finestra ultimi 60 s
   e risponde con `HRV_RESULT`. Questo è il pattern imposto dal fatto che
   l'Instinct Solar 2X fornisce HRV affidabile solo on-demand, non in streaming.

### Protocollo messaggi JSON

```
App ▶ Watch: {"type":"START_SESSION","hz":4}
App ▶ Watch: {"type":"REQUEST_HRV","reqId":42}
App ▶ Watch: {"type":"STOP_SESSION"}

Watch ▶ App: {"type":"STATE","v":"READY|ACTIVE|ERROR"}
Watch ▶ App: {"type":"HR_SAMPLE","t":<unixMs>,"bpm":<int>,"rr":<int?>}
Watch ▶ App: {"type":"HRV_RESULT","reqId":42,"t":<unixMs>,
              "rmssd":<int>,"sdnn":<int>,"rr":[<int>,...]}
```

## Setup di sviluppo

### Pre-requisiti

- Flutter **3.41+** (Dart 3.11)
- Android Studio / Xcode per build mobile
- [Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) ≥ 7.1 + simulatore per l'app watch
- [Connect IQ Mobile SDK](https://developer.garmin.com/connect-iq/core-topics/mobile-sdk/) (da integrare nel bridge Android/iOS)

### Build dell'app Flutter

```bash
cd hrv_trainer
flutter pub get
flutter run           # mobile collegato
flutter test          # unit test (include metriche HRV)
```

In **debug** il backend HR è in modalità `mock`: simula una RSA a 6 bpm, così puoi esercitare la UI senza il watch. In **release** viene usata la `GarminCiqSource`.

### Build dell'app Connect IQ

1. Installa il Connect IQ SDK manager e il device profile dell'**Instinct Solar 2X** (`instinct2x`).
2. Apri `hrv_watch_ciq/` in VS Code con l'estensione Monkey C.
3. Rigenera un UUID (`Monkey C: Generate UUID`) e sostituiscilo in `manifest.xml`.
4. Fornisci un `launcher_icon.png` (28×28 o 40×40) in `resources/drawables/`.
5. `Build for Device` e installa il `.prg` sul watch.

### Connessione fra Flutter e Watch

1. Installare l'app **Garmin Connect Mobile** sul telefono e associare l'Instinct Solar 2X.
2. Scaricare da [developer.garmin.com](https://developer.garmin.com/connect-iq/sdk/) il **Connect IQ Mobile SDK - Android** (`.aar`) e copiarlo in `hrv_trainer/android/app/libs/` (vedi `libs/README.md`).
3. Il bridge Kotlin (`GarminCiqBridge.kt`) rileva l'SDK a runtime **via reflection**: se presente parla col watch, se assente ricade automaticamente su un simulatore interno (nessun cambio codice richiesto). Controlla `logcat` con tag `GarminCiqBridge` per verificare quale backend è attivo.
4. L'UUID dell'app CIQ è condiviso fra `manifest.xml` e `GarminCiqBridge.kt` (costante `CIQ_APP_UUID = 53acf5c77bd74bc1bd3475f41ffec345`).

## Flussi principali dell'app

1. **Assessment Frequenza di Risonanza** — scansione guidata a 6.5 / 6.0 / 5.5 / 5.0 / 4.5 bpm (2,5 min ciascuna). L'app analizza SDNN, picco LF e sincronia di fase e propone la tua RF personale.
2. **Training 20 min** — pacer alla RF scelta, HR live, metriche aggiornate ogni 5 s, salvataggio a fine sessione.
3. **Pacer libero** — respirazione guidata senza registrazione. Utile per rescue sessions e familiarizzazione.
4. **Storico + trend** — grafico SDNN/RMSSD sulle ultime N sessioni, marker morning readiness.

## Stato attuale

- ✅ Dominio HRV (time-domain + stima LF via Lomb-Scargle)
- ✅ UI pacer, assessment, training, storico
- ✅ Persistenza sqflite
- ✅ Bridge Android Connect IQ via reflection (real + mock fallback)
- ✅ App CIQ Monkey C con protocollo JSON bidirezionale
- ✅ Icone launcher Android (mipmap + adaptive) e CIQ generate via `tools/generate_icons.py`
- ✅ UUID CIQ condiviso (`53acf5c77bd74bc1bd3475f41ffec345`)
- ✅ Connect IQ Mobile SDK (`monkeybrains-sdk-release.aar`) integrato in `android/app/libs/`
- ✅ Signing config release dedicato (`android/keystore/release.jks`, `android/key.properties`) + proguard rules per preservare classi CIQ
- ✅ Build release verificata (APK firmato con keystore locale)

## Per chi forka — cosa devi fornire tu

Il repository **non include** i materiali coperti da licenze di terze parti o da credenziali personali. Prima di buildare:

| Cosa | Dove va | Come ottenerlo |
|---|---|---|
| **Connect IQ Mobile SDK Android** (`monkeybrains-sdk-release.aar`) | `hrv_trainer/android/app/libs/` | Download manuale da [developer.garmin.com](https://developer.garmin.com/connect-iq/core-topics/mobile-sdk/) — licenza Garmin proprietaria |
| **Connect IQ SDK + simulatore + device profile `instinct2x`** | installazione locale | [Connect IQ SDK Manager](https://developer.garmin.com/connect-iq/sdk/) |
| **Chiavi developer CIQ** (`developer_key.der/.pem`) | `hrv_watch_ciq/keys/` | Generate con il comando `Monkey C: Generate Developer Key` di VS Code |
| **Keystore Android release** (`release.jks`) | `hrv_trainer/android/keystore/` | `keytool -genkeypair -v -keystore release.jks -alias <tuo-alias> -keyalg RSA -keysize 2048 -validity 10000` |
| **`key.properties`** con le password del keystore | `hrv_trainer/android/key.properties` | Crealo tu (vedi formato sotto) |
| **UUID dell'app CIQ** | `hrv_watch_ciq/manifest.xml` + `GarminCiqBridge.kt` (`CIQ_APP_UUID`) | Genera il tuo con `Monkey C: Generate UUID` e sostituiscilo in entrambi i file |

Formato `key.properties`:

```properties
storeFile=keystore/release.jks
storePassword=<your-store-password>
keyAlias=<your-alias>
keyPassword=<your-key-password>
```

In **debug** l'SDK Garmin non serve: il bridge Kotlin rileva l'assenza dell'`.aar` via reflection e ricade su un simulatore HR interno (RSA a 6 bpm). Puoi quindi sviluppare la UI Flutter senza watch né SDK.

## Licenza

[MIT](./LICENSE) — Copyright © 2025-2026 Matteo Preda.

Progetto indipendente, **non affiliato a Garmin Ltd.** "Garmin", "Connect IQ" e "Instinct" sono marchi di Garmin Ltd.
