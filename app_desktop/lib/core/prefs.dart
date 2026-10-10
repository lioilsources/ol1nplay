import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-machine UI preferences (pane widths, window bounds, engine
/// override). Engine-side settings live in the engine; this is only what
/// the desktop shell itself needs before it has a connection.
class Prefs extends ChangeNotifier {
  Prefs(this._sp);

  final SharedPreferences _sp;

  static Future<Prefs> load() async =>
      Prefs(await SharedPreferences.getInstance());

  /// In-memory prefs for tests (call after SharedPreferences.setMockInitialValues).
  @visibleForTesting
  static Future<Prefs> memory() async =>
      Prefs(await SharedPreferences.getInstance());

  double get treeWidth => _sp.getDouble('pane.tree') ?? 260;
  double get nowPlayingWidth => _sp.getDouble('pane.now') ?? 360;
  set treeWidth(double v) => _set(() => _sp.setDouble('pane.tree', v));
  set nowPlayingWidth(double v) => _set(() => _sp.setDouble('pane.now', v));

  String get engineOverride => _sp.getString('engine.override') ?? '';
  set engineOverride(String v) =>
      _set(() => _sp.setString('engine.override', v));

  String get lastDir => _sp.getString('library.lastDir') ?? '';
  set lastDir(String v) => _set(() => _sp.setString('library.lastDir', v));

  List<double>? get windowBounds {
    final l = _sp.getStringList('window.bounds');
    if (l == null || l.length != 4) return null;
    return l.map(double.parse).toList();
  }

  set windowBounds(List<double>? v) => _set(
    () => v == null
        ? _sp.remove('window.bounds')
        : _sp.setStringList(
            'window.bounds',
            v.map((d) => d.toString()).toList(),
          ),
  );

  bool get miniPlayer => _sp.getBool('window.mini') ?? false;
  set miniPlayer(bool v) => _set(() => _sp.setBool('window.mini', v));

  String get middleView => _sp.getString('view.middle') ?? 'folder';
  set middleView(String v) => _set(() => _sp.setString('view.middle', v));

  bool get showLog => _sp.getBool('view.log') ?? false;
  set showLog(bool v) => _set(() => _sp.setBool('view.log', v));

  void _set(Future<void> Function() f) {
    f();
    notifyListeners();
  }
}
