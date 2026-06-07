# Connect IQ Mobile SDK — accesso via reflection in GarminCiqBridge.kt.
# Preserviamo TUTTE le classi del package per permettere Class.forName()
# e la creazione di dynamic proxy delle interfacce listener.
-keep class com.garmin.android.connectiq.** { *; }
-keep interface com.garmin.android.connectiq.** { *; }
-keepattributes InnerClasses,Signature,EnclosingMethod

# Aidl interfaces del servizio Connect IQ.
-keep class com.garmin.android.apps.connectmobile.connectiq.** { *; }

# Flutter plugins — già coperte dalle default rules di Flutter, ma
# ribadiamo per sicurezza sui method channel custom.
-keep class com.dev.hrv_trainer.** { *; }

# flutter_local_notifications: il plugin (de)serializza le notifiche
# schedulate via Gson + reflection (models.NotificationDetails,
# RuntimeTypeAdapterFactory), ricostruendole nel receiver di alarm/boot.
# Senza queste keep-rule R8 in release rinomina/strippa i campi → Gson
# fallisce e i promemoria non scattano (in particolare dopo un riavvio).
# Bug subdolo perché invisibile in debug. Vedi memoria project_notifications.
-keep class com.dexterous.** { *; }
-keep class com.google.gson.** { *; }
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn com.dexterous.**
