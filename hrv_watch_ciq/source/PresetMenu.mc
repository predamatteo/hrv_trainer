using Toybox.WatchUi as Ui;
using Toybox.Application as App;

// Menu nativo di scelta sessione, mostrato da IDLE con GPS. Otto voci:
// i 7 preset clinici (SessionPresets) + "Libero" (config manuale da zero).
//
// Il menu è costruito ON-DEMAND (solo a orologio fermo, IDLE) e rilasciato
// appena l'utente sceglie: così il picco di memoria del Menu2 non coincide
// MAI con una sessione attiva (streaming HR + eventuali buffer), quando il
// pool CIQ ~96 KB del 2X è più a rischio OOM. A sessione in corso il menu non
// esiste più in memoria.
class PresetMenu {
    // Costruisce il Menu2. Gli id delle voci preset sono l'indice 0..6;
    // la voce "Libero" usa il Symbol :libero per distinguerla senza collidere
    // con gli indici.
    static function build() {
        var menu = new Ui.Menu2({ :title => "Sessione" });
        for (var i = 0; i < SessionPresets.COUNT; i++) {
            menu.addItem(new Ui.MenuItem(
                SessionPresets.label(i),
                SessionPresets.subLabel(i),
                i,
                null));
        }
        menu.addItem(new Ui.MenuItem(
            "Libero",
            "Imposta tu",
            :libero,
            null));
        return menu;
    }
}

// Delegate del menu di scelta sessione. Su SELECT porta la View base nella
// schermata di config appropriata (preset → solo durata; libero → carosello
// completo) e chiude il menu, rivelando la View sottostante.
class PresetMenuDelegate extends Ui.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    function onSelect(item) {
        var id = item.getId();
        var view = App.getApp().getView();
        if (view != null) {
            if (id == :libero) {
                view.enterLiberoConfig();
            } else {
                view.enterPresetConfig(id);
            }
        }
        // Chiude il menu e rivela la View base (ora in SCREEN_CONFIG).
        Ui.popView(Ui.SLIDE_RIGHT);
    }

    function onBack() {
        // Chiusura senza scelta → torna a IDLE.
        Ui.popView(Ui.SLIDE_RIGHT);
    }
}
