using Toybox.SensorHistory as SensorHistory;
using Toybox.Math as Math;
using Toybox.Time as Time;
using Toybox.Communications as Comm;
using Toybox.Lang as Lang;

// Calcolo HRV "on demand" richiesto dal telefono.
// Sull'Instinct Solar 2X SENSOR_HEARTRATE non espone RR in streaming
// continuo: usiamo SensorHistory.getHeartRateHistory() sugli ultimi 60
// secondi e stimiamo RR ~ 60000/HR per ogni campione.
//
// Se il modello dovesse esporre in futuro getHeartBeatIntervalsHistory()
// (Fenix 7 / Forerunner 255+) rimpiazzare il loop di sotto per maggior
// precisione.
class HrvCompute {
    static function computeAndReply(reqId) {
        var samples = collectRecentRr(60);
        var rmssd = 0;
        var sdnn = 0;
        var rrOut = [];

        if (samples != null && samples.size() >= 10) {
            var n = samples.size();
            var sum = 0;
            for (var i = 0; i < n; i++) { sum += samples[i]; }
            var mean = sum.toFloat() / n;

            var sqSum = 0.0;
            for (var j = 0; j < n; j++) {
                var d = samples[j] - mean;
                sqSum += d * d;
            }
            // Sample stdev (n-1) per coerenza con la letteratura HRV.
            sdnn = Math.sqrt(sqSum / (n - 1)).toNumber();

            var sqDiff = 0.0;
            for (var k = 1; k < n; k++) {
                var dk = samples[k] - samples[k - 1];
                sqDiff += dk * dk;
            }
            rmssd = Math.sqrt(sqDiff / (n - 1)).toNumber();
            rrOut = samples;
        }

        var payload = {
            "type" => "HRV_RESULT",
            "reqId" => reqId,
            // .toLong() per evitare overflow Int32: Time.now().value() *
            // 1000 in Number wrappa silenziosamente nel 2026 (cfr.
            // HrSession.startInternal per i dettagli del bug).
            "t" => Time.now().value().toLong() * 1000l,
            "rmssd" => rmssd,
            "sdnn" => sdnn,
            "rr" => rrOut,
            // RR ricostruiti da SensorHistory HR (60000/bpm), non da
            // veri intervalli R-R. Trattare come stima.
            "rrSource" => "estimated_from_hr",
        };
        try {
            Comm.transmit(payload, null, new CommListener());
        } catch (ex) {
            // Phone non connesso: la richiesta REQUEST_HRV è arrivata
            // ma non possiamo rispondere. Niente da fare.
        }
    }

    // Ricostruisce una finestra di RR (ms) approssimati dagli ultimi
    // `seconds` secondi di storico HR.
    static function collectRecentRr(seconds) {
        var iter = SensorHistory.getHeartRateHistory({
            :period => new Time.Duration(seconds),
        });
        if (iter == null) { return []; }
        var out = [];
        var sample = iter.next();
        while (sample != null) {
            if (sample.data != null && sample.data > 0) {
                out.add(60000 / sample.data);
            }
            sample = iter.next();
        }
        return out;
    }
}
