# Connect IQ Mobile SDK (Android)

Questa cartella deve contenere la libreria Connect IQ Mobile SDK per Android, distribuita da Garmin come file `.aar`.

## Come ottenerla

1. Registrati come sviluppatore su [developer.garmin.com](https://developer.garmin.com/connect-iq/sdk/).
2. Scarica **"Connect IQ Mobile SDK - Android"** (file tipo `connectiq-mobile-sdk-android-x.y.z.aar`).
3. Copialo in questa cartella (`hrv_trainer/android/app/libs/`).
4. Ricompila l'app: `flutter clean && flutter run`.

## Funzionamento a runtime

Il bridge `GarminCiqBridge.kt` rileva automaticamente la presenza dell'SDK via reflection:

- **aar presente** → il bridge usa l'SDK reale, parla con la CIQ app sull'Instinct Solar 2X attraverso Garmin Connect Mobile.
- **aar assente** → il bridge passa in modalità **mock**, genera eventi HR simulati (RSA a 6 bpm) e risposte HRV finte. Utile per sviluppare senza hardware né SDK.

Lo stato (`REAL` / `MOCK`) viene loggato all'avvio in `logcat` con tag `GarminCiqBridge`.
