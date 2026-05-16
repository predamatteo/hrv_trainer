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
