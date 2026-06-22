import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Nome utente per il saluto in Home ("Buongiorno, `<nome>`"). Persistito in
/// SharedPreferences; `null`/vuoto ⇒ saluto senza nome. Si imposta da Profilo.
class UserNameController extends StateNotifier<String?> {
  UserNameController() : super(null) {
    _load();
  }

  static const String _key = 'user_name_v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_key)?.trim();
    state = (v == null || v.isEmpty) ? null : v;
  }

  Future<void> setName(String value) async {
    final v = value.trim();
    state = v.isEmpty ? null : v;
    final prefs = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await prefs.remove(_key);
    } else {
      await prefs.setString(_key, v);
    }
  }
}

final userNameProvider =
    StateNotifierProvider<UserNameController, String?>((ref) => UserNameController());
