/// Lenient JSON accessors. The engine omits zero-valued fields
/// (`omitempty`), so every reader must tolerate a missing key.
library;

typedef Json = Map<String, dynamic>;

String str(Json j, String k, [String d = '']) {
  final v = j[k];
  return v is String ? v : d;
}

int integer(Json j, String k, [int d = 0]) {
  final v = j[k];
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? d;
  return d;
}

double dbl(Json j, String k, [double d = 0]) {
  final v = j[k];
  if (v is num) return v.toDouble();
  return d;
}

bool boolean(Json j, String k, [bool d = false]) {
  final v = j[k];
  return v is bool ? v : d;
}

Json? obj(Json j, String k) {
  final v = j[k];
  return v is Map ? Map<String, dynamic>.from(v) : null;
}

List<T> list<T>(Json j, String k, T Function(Json) f) {
  final v = j[k];
  if (v is! List) return const [];
  return v
      .whereType<Map>()
      .map((e) => f(Map<String, dynamic>.from(e)))
      .toList(growable: false);
}

List<String> strings(Json j, String k) {
  final v = j[k];
  if (v is! List) return const [];
  return v.whereType<String>().toList(growable: false);
}

List<int> ints(Json j, String k) {
  final v = j[k];
  if (v is! List) return const [];
  return v.whereType<num>().map((e) => e.toInt()).toList(growable: false);
}

/// Drops nulls and empty strings so our JSON looks like the Go side's.
Json compact(Json j) {
  j.removeWhere((_, v) => v == null || (v is String && v.isEmpty));
  return j;
}
