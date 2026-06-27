using Toybox.Math as Math;

// Filtro HRV condiviso dai due percorsi del watch — HRV on-demand
// (HrvCompute.computeAndReply) e SESSION_SUMMARY standalone
// (HrSession.buildSummary) — che prima copiavano le STESSE soglie e formule.
// Centralizzando, un eventuale cambio di soglia (nuove linee guida o taratura
// per gli RR stimati da HR 1 Hz dell'Instinct 2X) resta atomico e i due
// percorsi non possono divergere.
class HrvFilter {
    // Gate fisiologico: scarta i battiti impossibili.
    static const MIN_MS = 300;
    static const MAX_MS = 2000;
    // Anti-spike: scarta i salti spuri dovuti a HR sample mancanti.
    static const MAX_DELTA_MS = 250;
    // Minimo di campioni puliti per statistiche time-domain stabili.
    static const MIN_SAMPLES = 10;

    // Gate fisiologico + anti-spike. Ritorna un NUOVO array di RR (ms) puliti.
    static function clean(rrList) {
        var out = [];
        if (rrList == null) { return out; }
        var prev = null;
        for (var i = 0; i < rrList.size(); i++) {
            var v = rrList[i];
            if (v < MIN_MS || v > MAX_MS) { continue; }
            if (prev != null && (v - prev).abs() > MAX_DELTA_MS) { continue; }
            out.add(v);
            prev = v;
        }
        return out;
    }

    // SDNN (ms, sample stdev n-1) su una serie GIA' pulita. 0 se meno di
    // MIN_SAMPLES campioni.
    static function sdnn(cleaned) {
        var n = cleaned.size();
        if (n < MIN_SAMPLES) { return 0; }
        var sum = 0;
        for (var i = 0; i < n; i++) { sum += cleaned[i]; }
        var mean = sum.toFloat() / n;
        var sq = 0.0;
        for (var j = 0; j < n; j++) {
            var d = cleaned[j] - mean;
            sq += d * d;
        }
        return Math.sqrt(sq / (n - 1)).toNumber();
    }

    // RMSSD (ms, n-1) su una serie GIA' pulita. 0 se meno di MIN_SAMPLES.
    static function rmssd(cleaned) {
        var n = cleaned.size();
        if (n < MIN_SAMPLES) { return 0; }
        var sqd = 0.0;
        for (var k = 1; k < n; k++) {
            var dk = cleaned[k] - cleaned[k - 1];
            sqd += dk * dk;
        }
        return Math.sqrt(sqd / (n - 1)).toNumber();
    }
}
