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
    // Contatore persistente di summary scartati per buffer pieno: viaggia nel
    // prossimo SESSION_SUMMARY così il phone può avvisare di una perdita dati
    // standalone (prima il drop era silenzioso). Azzerato a ogni ack (= phone
    // di nuovo raggiungibile, conteggio gia` comunicato).
    static const DROPPED_KEY = "droppedSummaries";
    static const MAX_PENDING = 5;

    // Aggiunge un summary alla coda. Se il cap è raggiunto, scarta il più
    // vecchio (FIFO). Il summary deve avere chiave "startMs" che fa da id.
    static function add(summary) {
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { list = []; }
        list.add(summary);
        var dropped = 0;
        while (list.size() > MAX_PENDING) {
            list = list.slice(1, list.size());
            dropped++;
        }
        if (dropped > 0) {
            var prev = Storage.getValue(DROPPED_KEY);
            if (!(prev instanceof Toybox.Lang.Number)) { prev = 0; }
            Storage.setValue(DROPPED_KEY, prev + dropped);
            Sys.println("PendingStore.add: DROPPED " + dropped +
                " (total " + (prev + dropped) + ") — phone irraggiungibile");
        }
        Storage.setValue(KEY, list);
        Sys.println("PendingStore.add: now size=" + list.size());
    }

    // Numero di summary scartati dall'ultimo ack (perdita dati standalone).
    static function droppedCount() {
        var v = Storage.getValue(DROPPED_KEY);
        if (!(v instanceof Toybox.Lang.Number)) { return 0; }
        return v;
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
        // Phone raggiungibile: azzera il contatore dei droppati (il valore e'
        // gia` stato comunicato nei SESSION_SUMMARY inviati finora).
        Storage.setValue(DROPPED_KEY, 0);
        Sys.println("PendingStore.ack startMs=" + startMs + " remaining=" + kept.size());
    }

    static function size() {
        var list = Storage.getValue(KEY);
        if (!(list instanceof Toybox.Lang.Array)) { return 0; }
        return list.size();
    }
}
