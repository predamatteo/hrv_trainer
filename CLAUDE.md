# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Two apps that talk over Bluetooth to do HRV biofeedback training (Lehrer-Gevirtz resonance-frequency breathing, ~0.1 Hz) using a **Garmin Instinct Solar 2X** as the HR sensor. **Android only** (iOS not supported). Not a medical device.

- `hrv_trainer/` — Flutter (Dart 3.11) phone app: pacer, resonance assessment, 20-min training, morning readiness, history/trend.
- `hrv_watch_ciq/` — Connect IQ (Monkey C) watch app: keeps the HR sensor on, streams `HR_SAMPLE` per beat, computes HRV on demand.
- `connectiq-android-sdk-main/` — vendored Garmin sample, reference only.
- `tools/generate_icons.py` — regenerates Android + CIQ launcher icons.
- `research.md`, `*.md` (HRV science notes) — domain background, not code.

User-facing strings and most code comments are in **Italian**; keep that convention.

## Commands

All Flutter commands run from `hrv_trainer/`:

```bash
flutter pub get
flutter analyze                       # lint (flutter_lints)
flutter test                          # all unit tests
flutter test test/hrv_metrics_test.dart            # single file
flutter test --plain-name "resonance"              # single test by name
flutter build apk                     # release APK (needs keystore, see below)
```

### Installing / updating the phone app — IMPORTANT

**Never run `flutter install`.** It can uninstall the existing app and wipe the sqflite database (this has happened — see backup feature).

**The required workflow: always check if the app is already on the device first, then update it in place (preserving data) if present, or do a clean install if not.** Package id is `com.dev.hrv_trainer`.

PowerShell (this environment's default shell):

```powershell
flutter build apk
$pkg = "com.dev.hrv_trainer"
$apk = "build/app/outputs/flutter-apk/app-release.apk"
if (adb shell pm list packages | Select-String $pkg) {
  adb install -r $apk    # already installed → UPDATE in place, keeps the DB
} else {
  adb install $apk       # not present → fresh INSTALL
}
```

Bash equivalent:

```bash
flutter build apk
PKG=com.dev.hrv_trainer
APK=build/app/outputs/flutter-apk/app-release.apk
if adb shell pm list packages | grep -q "$PKG"; then
  adb install -r "$APK"   # UPDATE, preserves data
else
  adb install "$APK"      # fresh INSTALL
fi
```

The `-r` (reinstall) flag is what preserves the database — never use `adb uninstall` then install. `flutter run` for live development is fine.

### Installing / updating the watch app

Same principle on the Connect IQ side: before sideloading a new `.prg`, check whether HRV Trainer is already on the watch and update rather than remove-and-readd (removing the CIQ app clears its `PendingStore`, dropping any unsynced stand-alone sessions). There's no `adb` here — sideload from VS Code (`Build for Device`) or Garmin Express, which overwrites the existing app in place when the `CIQ_APP_UUID` matches.

### Connect IQ watch app

Built from VS Code with the Monkey C extension (no CLI here): `Build for Device`, then sideload the `.prg`. Target device profile is `instinct2x` (also targets `instinct2`/`instinct2s`).

## Architecture

### The two-app split and why it exists

The Instinct Solar 2X does **not** stream true beat-to-beat RR intervals. It exposes HR at ~1 Hz, and reliable HRV only **on demand**. This single hardware constraint shapes the whole design:

- The watch app streams `HR_SAMPLE` (bpm, optional rr, elapsedMs) per beat and computes RMSSD/SDNN only when the phone sends `REQUEST_HRV`.
- The phone reconstructs RR from HR when native RR is absent (`HeartRateEvent.toRr()` → `60000/bpm`), tagging the data `estimated_from_hr`.
- Because RR is estimated from 1 Hz HR, the HF band (0.15–0.40 Hz) is past Nyquist and **RMSSD systematically underestimates** vs Garmin's native Health Snapshot (~10% low). This is a known limit, not a bug. Confidence is capped (never `high`) for estimated sources, and the resonance assessment leans on the ~0.1 Hz respiratory wave (peak-to-trough, LF power) which *is* within Nyquist.

JSON message protocol (full details in `README.md`): `START_SESSION`/`REQUEST_HRV`/`STOP_SESSION` phone→watch; `STATE`/`HR_SAMPLE`/`HRV_RESULT`/`SESSION_SUMMARY` watch→phone.

### Phone↔native bridge (Flutter ↔ Connect IQ Mobile SDK)

- Dart side: `lib/shared/connect_iq/garmin_ciq_source.dart` over `MethodChannel('dev.hrv/garmin_ciq')` + `EventChannel('dev.hrv/garmin_ciq_events')`.
- Native side: `android/app/src/main/kotlin/com/dev/hrv_trainer/GarminCiqBridge.kt` (+ `MainActivity.kt` wires the channels). Methods: `start`, `stop`, `forceStop`, `reconnect`, `requestHrv`, `summaryAck`, `requestSync`, `listDevices`.
- **Reflection fallback:** the bridge detects the Connect IQ Mobile SDK (`monkeybrains-sdk-release.aar`) *at runtime via reflection*. If the `.aar` is present it talks to the real watch; if absent it falls back to an internal HR simulator — **no code change needed**. Check `logcat -s GarminCiqBridge` to see which backend is live.
- Note: the Dart `hrBackendProvider` defaults to `HrBackend.garminCiq` in *all* builds (debug included). The "develop without hardware" path is the native reflection fallback above — **not** a Dart debug flag. `HrBackend.mock` (`MockHeartRateSource`, simulated 6 bpm RSA) exists but isn't auto-selected.
- The `CIQ_APP_UUID = 53acf5c77bd74bc1bd3475f41ffec345` is duplicated in `GarminCiqBridge.kt` and `hrv_watch_ciq/manifest.xml` — change both together.

### HR source abstraction

`HeartRateSource` (`heart_rate_source.dart`) is the central interface; implementations: `GarminCiqSource`, `MockHeartRateSource`, (BLE chest-strap fallback via `flutter_blue_plus` is planned). Wired through Riverpod in `hr_source_provider.dart` (`heartRateSourceProvider`, `hrSourceStateProvider`, `heartRateStreamProvider`). Stand-alone sessions started from the watch arrive as `RemoteSessionSummary` and are persisted by `remote_session_persister.dart`.

**Stand-alone session recovery:** Garmin Connect Mobile does not buffer messages when no listener is registered, so summaries from watch-initiated sessions can be orphaned in the watch's `PendingStore`. On app resume (`main.dart`), the app calls `reconnect()` + silent `requestSync()` to drain them; an explicit "Sincronizza" button does a forceful `requestSync(force: true)` (wakes the watch app).

### HRV domain (`lib/shared/hrv/`)

Pure Dart, no Flutter deps — this is the well-tested core.

- `hrv_metrics.dart` — `HrvCalculator.compute()` is the pipeline: artifact cleaning (physiological gate 300–2000ms + moving-median spike detection, wider threshold for `estimated_from_hr`), then time-domain (SDNN, RMSSD, pNN50, sample variance n−1), **Lomb-Scargle periodogram** (`spectrum()`, handles non-uniform RR sampling) for LF/HF band power + peaks, Poincaré (SD1/SD2), and a HeartMath-style `coherenceRatio` (the key biofeedback signal on 1 Hz data). HRV score = `15.385 * ln(RMSSD)` clamped 0–100 — single source is `HrvMetrics.scoreFromRmssd()`, reuse it, don't re-inline the constant.
- `session_models.dart` — `Session`/`SessionTag`/`SessionKind`. `SessionTag` carries clinical defaults (`defaultPattern`, `defaultDurationMin`, `rationale`) per context (morning/stress/sleep/…). `ResonanceAssessment.analyze()` picks the resonance frequency by **maximizing respiratory oscillation amplitude** across the 5 scanned rates (peak-to-trough weighted 0.45, LF power 0.30, SDNN 0.10, coherence 0.15).
- Other modules: `breathing_pacer.dart`, `readiness.dart`/`morning_reading.dart`, `hrv_trend.dart`, `hrv_interpretation.dart`, `dashboard_stats.dart`, plus reusable chart widgets in `widgets/`.

When adding/changing metric math, add or update the matching `test/*_test.dart` — the domain has real coverage (`hrv_metrics_test`, `resonance_assessment_test`, `hrv_trend_test`, `readiness_test`, `dashboard_stats_test`, `hrv_interpretation_test`).

### Persistence

`lib/shared/storage/database.dart` — sqflite, **currently version 4**. Tables: `sessions` (metrics/pattern/morning-meta/post-session-report as JSON columns, optional `plan_id`), `assessments`, `rr_samples` (FK cascade), `training_plans` (the plan as `plan_json` + queryable `status`). Migrations are additive `ALTER TABLE ... ADD COLUMN` only — preserve that pattern (v2 added `tag`, v3 added `morning_meta_json`, v4 added `training_plans` + `plan_id` + `post_session_report_json`). `session_repository.dart` is the data API, including `exportAll()`/`importAll()` (JSON backup, **schema v3** now — exports plans + report and re-maps `plan_id` on import; dedup on `startedAt`/`created_at`) for the manual Drive/email backup feature.

### Training plan (`lib/shared/training_plan/` + `features/training_plan/`)

The **Piano di allenamento**: a 4-week, flexible, adaptive program that turns isolated sessions into a coached journey. Evidence-grounded (see the design notes in `plan_models.dart` — ramp-up, process-not-outcome goal, forgiving streaks, interoceptive logging).

- `plan_models.dart` — pure Dart. `TrainingPlan` (goal/scopo, status, ladder, resonance seed, implementation intention, reminder time), `kDefaultPlanLadder` (ramp 4→18 min, 4→5×/week — the **one** place to tune the curve), and `computePlanProgress(plan, completedTimes, now)`: a **pure, deterministic** engine. Weeks are rolling 7-day windows from `startedAt`; a level advances only on ≥80% of that week's target (`planAdvanceThreshold`), and missed weeks **hold** the level (never punish). It detects graduation (last level met → re-assessment "diploma").
- `post_session_report.dart` — `PostSessionReport` (pre-tension, post-calm, mood, interocettive `BodySensation` chips, note) + `calmDelta`. A field on `Session`; kept in its own file to avoid a `session_models`↔`plan_models` import cycle (`plan_models` re-exports it).
- `plan_providers.dart` — `assessmentGateProvider` (the plan **requires** a usable resonance assessment; `kAssessmentValidityDays`=60 only *recommends* a refresh), `activePlanProvider`/`planProgressProvider`/`planSessionTimesProvider`, and `PlanController` (create/abandon/`onPlanSessionSaved` → marks completed at graduation). At most **one active plan**.
- `features/training_plan/` — `piano_screen.dart` (empty-state pitch / active plan: scopo, week adherence ring, calendar grid, cumulative milestone, today CTA, graduation), `plan_setup_screen.dart` (assessment-gated creation), `widgets/post_session_report_sheet.dart` (pre-tension + post-session report sheets).
- Plan reminders: `shared/notifications/plan_reminder.dart` — separate ID/payload from the generic reminders (see Notifications), reconciled on startup/resume/plan-change.
- A plan session is a normal training `Session` with `plan_id` set; the training flow (`features/training/`) pre-fills from `/training?planId&dur&bpm`, captures pre-tension before measuring, and shows the report sheet after. Counting/adherence is purely `plan_id` + a completed `ended_at`.

### Phone app structure

Riverpod + go_router. **4-tab bottom-nav shell** via `StatefulShellRoute.indexedStack` in `core/router/app_router.dart`: branches Home (`/`), Sessione (`/sessione` — practice hub in `features/sessione/`), Piano (`/piano` — training-plan hub in `features/training_plan/`, with `/piano/setup`), Storico (`/history`). **Profilo/Impostazioni is NOT a tab**: `/settings` is a top-level root-navigator route reached via the gear icon (`shared/ui/SettingsButton`) top-right on the 4 screens. `/hrv` (Andamento HRV) and `/readiness` are children of the Home branch; `/history/session/:id` is a child of Storico. The immersive flows (`/training`, `/pacer`, `/assessment`, `/readiness/checkin`) are **top-level routes with `parentNavigatorKey = rootNavigatorKey`** so they cover the bottom nav (modal in spirit — wakelock + `PopScope`). `/training` accepts `?planId&dur&bpm` to pre-fill and tag a plan session. The shell widget is `core/router/scaffold_with_nav_bar.dart`. Each `features/<name>/` holds its screen + `state/` controller(s) + `widgets/`.

**Design system** (`core/theme/`): `AppTokens` (`app_tokens.dart`) is a `ThemeExtension` with the full light/dark semantic palette (petrol primary, moss accent, inhale/exhale, good/warn/alert + tonals, surface/tonal/tonal2, line, grid). `app_theme.dart` does `ColorScheme.fromSeed(...).copyWith(...)` **pinning** the load-bearing roles onto the tokens so stock Material widgets (Card/Chip/NavigationBar/buttons) stay on-brand for free; bespoke needs read `context.tokens.<x>` — **use tokens, not hardcoded hex** (the only deliberate exceptions are the categorical `tagColor`/`qualityColor` in `session_chart_utils.dart`, intentionally theme-independent). Font is **Figtree, bundled offline** under `assets/fonts/` (4 weights, declared in pubspec `fonts:`) — do **not** switch to `google_fonts` (the morning flow can't depend on a network fetch); numeric `TextTheme` styles carry tabular figures. Shared UI components live in `lib/shared/ui/` (`AppCard`, `Pill`/`PillTone`, `StatTile`/`MetricRow`, `ReadinessRing`, `CoherenceBar`, `HeaderBar`, `SectionHeader`, `CircleControlButton`); the animated breathing orb is `features/pacer/widgets/breathing_orb.dart`. `main.dart` initializes the `it_IT` intl locale (`initializeDateFormatting` + `GlobalMaterialLocalizations`) — required for Italian date/time formatting. The Home greeting name persists via `shared/profile/user_profile_provider.dart`. Local reminder notifications via `shared/notifications/`.

**Morning check-in flow** (`features/readiness/morning_checkin_screen.dart`): `idle → measuring → review (a SEPARATE context step: sleep/factors/fatigue) → saved (a readiness dashboard reading `readinessSectionProvider`)`. The live-measure widgets in `shared/hrv/widgets/live_session_view.dart` are shared by both check-in and training (see the unified-measure note).

## Gotchas

- **`flutter_local_notifications` is pinned to a DEV version** (`22.0.0-dev.3`) because of Dart 3.11 — do **not** "fix" it to a stable release; stable doesn't support the SDK yet.
- `test/widget_test.dart` "App avvia senza crash" is now deterministic: it seeds the `it_IT` locale + mock `SharedPreferences`, forces the **mock** HR backend (`hrBackendProvider` override), and pumps 3s to drain `RemoteSessionPersister`'s one-shot 2s sync timer (the old pre-existing "pending timer" flake). If you change app startup, keep this smoke test green.
- Garmin session protocol quirks: `START_SESSION` has ~17s latency, `STATE:READY` is not guaranteed, and the watch has its own auto-stop independent of the phone.
- **Two notification families coexist.** Generic reminders use IDs `1000+` / payload `training_reminder`; the plan reminder uses ID `2000` / payload `plan_reminder`. The reminder flow cancels **by payload** (`NotificationService.cancelReminders` / `cancelPlanReminders`, via `pendingNotificationRequests`), NOT `cancelAll` — so the two never clobber each other. Don't reintroduce `cancelAll()` in the reminder paths.

## Secrets / fork setup (gitignored, must be provided locally)

Not in the repo (see root `.gitignore`): `android/app/libs/*.aar` (Connect IQ Mobile SDK), `android/keystore/*.jks`, `android/key.properties`, `hrv_watch_ciq/keys/developer_key.*`. Release signing reads `android/key.properties`. Full provisioning table is in `README.md`.
