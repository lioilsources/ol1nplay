/// "3:07", "1:02:45"; negative or unknown → "–:––".
String fmtDuration(int ms) {
  if (ms < 0) return '–:––';
  final s = ms ~/ 1000;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  final sec = s % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(sec)}' : '$m:${two(sec)}';
}

/// "3:07.250" – for the A-B markers, where 10 ms matters.
String fmtDurationMs(int ms) {
  if (ms < 0) return '–:––.–––';
  final frac = (ms % 1000).toString().padLeft(3, '0');
  return '${fmtDuration(ms)}.$frac';
}

/// "12.3 MB", "1.2 GB".
String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = b / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

/// "44.1 kHz", "2.8224 MHz" for DSD.
String fmtHz(int hz) {
  if (hz <= 0) return '–';
  if (hz >= 1000000) {
    return '${(hz / 1000000).toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')} MHz';
  }
  final k = hz / 1000;
  return '${k == k.roundToDouble() ? k.round() : k.toStringAsFixed(1)} kHz';
}
