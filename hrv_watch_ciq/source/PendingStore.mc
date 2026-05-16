using Toybox.Application as App;
using Toybox.Application.Storage as Storage;
using Toybox.System as Sys;

// Buffer persistente di SESSION_SUMMARY non ancora confermati dal telefono.
//
// Il watch potrebbe trasmettere un summary mentre l'app Android è killata o
// mentre il phone è fuori range. In quei casi Comm.transmit cade nel vuoto.
// Per evitare la perdita dati salviamo ogni summary in Application.Storage
// finché il phone non risponde con un SUMMARY_ACK (matchato per startMs).
//
// Cap di sicurezza: max MAX_PENDING summary in memoria; oltre quel numero
// drop dei più vecchi (Storage CIQ ha pochi KB di spazio).
class PendingStore {
    static const KEY = "pendingSummaries";
    static const MAX_PENDING = 5;

    // Aggiunge un summary alla coda. Se il cap è raggiunto, scarta il più
    // vecchio (FIFO). Il summary deve avere chiave "startMs" che fa da id.
    static function add(summary) {
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { list = []; }
        list.add(summary);
        while (list.size() > MAX_PENDING) {
            list = list.slice(1, list.size());
        }
        Storage.setValue(KEY, list);
        Sys.println("PendingStore.add: now size=" + list.size());
    }

    // Ritorna la lista corrente (potenzialmente vuota).
    static function getAll() {
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { return []; }
        return list;
    }

    // Rimuove dalla coda l'eventuale summary col dato startMs.
    static function ack(startMs) {
        if (startMs == null) { return; }
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { return; }
        var kept = [];
        for (var i = 0; i < list.size(); i++) {
            var s = list[i];
            if (s instanceof Toybox.Lang.Dictionary && s["startMs"] != startMs) {
                kept.add(s);
            }
        }
        Storage.setValue(KEY, kept);
        Sys.println("PendingStore.ack startMs=" + startMs + " remaining=" + kept.size());
    }

    static function size() {
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { return 0; }
        return list.size();
    }
}
