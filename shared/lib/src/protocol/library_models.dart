import 'json_util.dart';

/// A library root directory.
class Root {
  const Root({
    required this.path,
    this.tracks = 0,
    this.dirs = 0,
    this.scanning = false,
    this.lastScan = 0,
    this.missing = false,
  });

  final String path;
  final int tracks;
  final int dirs;
  final bool scanning;

  /// Unix ms, 0 = never.
  final int lastScan;

  /// Drive unplugged etc.
  final bool missing;

  factory Root.fromJson(Json j) => Root(
    path: str(j, 'path'),
    tracks: integer(j, 'tracks'),
    dirs: integer(j, 'dirs'),
    scanning: boolean(j, 'scanning'),
    lastScan: integer(j, 'lastScan'),
    missing: boolean(j, 'missing'),
  );

  Json toJson() => {
    'path': path,
    'tracks': tracks,
    'dirs': dirs,
    'scanning': scanning,
    'lastScan': lastScan,
    'missing': missing,
  };

  /// Last path segment, for tiles.
  String get name => _baseName(path);
}

/// A directory in the tree; children are requested lazily.
class DirNode {
  const DirNode({
    required this.path,
    required this.name,
    this.hasDirs = false,
    this.tracks = 0,
    this.cover = '',
  });

  final String path;
  final String name;
  final bool hasDirs;

  /// Direct children only.
  final int tracks;

  /// Cover hash, if any.
  final String cover;

  factory DirNode.fromJson(Json j) => DirNode(
    path: str(j, 'path'),
    name: str(j, 'name'),
    hasDirs: boolean(j, 'hasDirs'),
    tracks: integer(j, 'tracks'),
    cover: str(j, 'cover'),
  );

  Json toJson() => compact({
    'path': path,
    'name': name,
    'hasDirs': hasDirs,
    'tracks': tracks,
    'cover': cover,
  });
}

/// Exact description of a PCM stream.
class Format {
  const Format({
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.channels = 0,
    this.sampleFormat = '',
    this.dsdRate = 0,
  });

  final int sampleRate;

  /// Meaningful bits (16, 24, 32); 0 for float.
  final int bitDepth;
  final int channels;

  /// "s16", "s24", "s32", "f32", "dsd", "dop".
  final String sampleFormat;

  /// DSD64 = 2822400.
  final int dsdRate;

  static const empty = Format();

  factory Format.fromJson(Json j) => Format(
    sampleRate: integer(j, 'sampleRate'),
    bitDepth: integer(j, 'bitDepth'),
    channels: integer(j, 'channels'),
    sampleFormat: str(j, 'sampleFormat'),
    dsdRate: integer(j, 'dsdRate'),
  );

  Json toJson() => compact({
    'sampleRate': sampleRate,
    'bitDepth': bitDepth,
    'channels': channels,
    'sampleFormat': sampleFormat,
    'dsdRate': dsdRate == 0 ? null : dsdRate,
  });

  bool get isEmpty => sampleRate == 0 && channels == 0;
  bool get isDsd =>
      sampleFormat == 'dsd' || sampleFormat == 'dop' || dsdRate > 0;
  bool get isFloat => sampleFormat.startsWith('f');

  /// "24/96", "32f/48", "DSD64".
  String get short {
    if (isDsd) return dsdLabel(dsdRate);
    final rate = sampleRateLabel(sampleRate);
    if (isFloat) return '${bitDepth == 0 ? 32 : bitDepth}f/$rate';
    return '$bitDepth/$rate';
  }

  @override
  String toString() => 'Format($sampleFormat $short ch=$channels)';

  @override
  bool operator ==(Object other) =>
      other is Format &&
      other.sampleRate == sampleRate &&
      other.bitDepth == bitDepth &&
      other.channels == channels &&
      other.sampleFormat == sampleFormat &&
      other.dsdRate == dsdRate;

  @override
  int get hashCode =>
      Object.hash(sampleRate, bitDepth, channels, sampleFormat, dsdRate);
}

/// "44.1k" style sample rate; whole kHz without decimals.
String sampleRateLabel(int hz) {
  if (hz <= 0) return '–';
  final k = hz / 1000;
  return k == k.roundToDouble() ? '${k.round()}k' : '${k.toStringAsFixed(1)}k';
}

/// DSD64/128/256/512 from a bit rate.
String dsdLabel(int dsdRate) {
  if (dsdRate <= 0) return 'DSD';
  final mult = (dsdRate / 44100).round();
  return 'DSD$mult';
}

/// One playable file, or one CUE track within a file.
class Track {
  const Track({
    required this.path,
    this.dir = '',
    this.fileName = '',
    this.title = '',
    this.artist = '',
    this.albumArtist = '',
    this.album = '',
    this.trackNo = 0,
    this.discNo = 0,
    this.year = 0,
    this.genre = '',
    this.composer = '',
    this.comment = '',
    this.codec = '',
    this.container = '',
    this.sampleRate = 0,
    this.bitDepth = 0,
    this.channels = 0,
    this.lossless = false,
    this.dsd = false,
    this.bitrate = 0,
    this.durationMs = 0,
    this.samples = 0,
    this.sizeBytes = 0,
    this.modTime = 0,
    this.cover = '',
    this.replayGain = 0,
    this.favorite = false,
    this.playCount = 0,
    this.lastPlayed = 0,
    this.hasLyrics = false,
    this.cueFile = '',
    this.cueStart = 0,
    this.cueEnd = 0,
  });

  final String path;
  final String dir;
  final String fileName;
  final String title;
  final String artist;
  final String albumArtist;
  final String album;
  final int trackNo;
  final int discNo;
  final int year;
  final String genre;
  final String composer;
  final String comment;

  /// "flac", "alac", "dsd", "mp3", ...
  final String codec;
  final String container;
  final int sampleRate;

  /// 0 for lossy / float.
  final int bitDepth;
  final int channels;
  final bool lossless;
  final bool dsd;

  /// kbps, lossy only.
  final int bitrate;
  final int durationMs;

  /// Total frames if known.
  final int samples;
  final int sizeBytes;

  /// Unix ms.
  final int modTime;

  /// Cover hash.
  final String cover;

  /// Displayed, never applied.
  final double replayGain;
  final bool favorite;
  final int playCount;
  final int lastPlayed;
  final bool hasLyrics;

  /// CUE sub-track: offset within the physical file (frames).
  final String cueFile;
  final int cueStart;
  final int cueEnd;

  factory Track.fromJson(Json j) => Track(
    path: str(j, 'path'),
    dir: str(j, 'dir'),
    fileName: str(j, 'fileName'),
    title: str(j, 'title'),
    artist: str(j, 'artist'),
    albumArtist: str(j, 'albumArtist'),
    album: str(j, 'album'),
    trackNo: integer(j, 'trackNo'),
    discNo: integer(j, 'discNo'),
    year: integer(j, 'year'),
    genre: str(j, 'genre'),
    composer: str(j, 'composer'),
    comment: str(j, 'comment'),
    codec: str(j, 'codec'),
    container: str(j, 'container'),
    sampleRate: integer(j, 'sampleRate'),
    bitDepth: integer(j, 'bitDepth'),
    channels: integer(j, 'channels'),
    lossless: boolean(j, 'lossless'),
    dsd: boolean(j, 'dsd'),
    bitrate: integer(j, 'bitrate'),
    durationMs: integer(j, 'durationMs'),
    samples: integer(j, 'samples'),
    sizeBytes: integer(j, 'sizeBytes'),
    modTime: integer(j, 'modTime'),
    cover: str(j, 'cover'),
    replayGain: dbl(j, 'replayGain'),
    favorite: boolean(j, 'favorite'),
    playCount: integer(j, 'playCount'),
    lastPlayed: integer(j, 'lastPlayed'),
    hasLyrics: boolean(j, 'hasLyrics'),
    cueFile: str(j, 'cueFile'),
    cueStart: integer(j, 'cueStart'),
    cueEnd: integer(j, 'cueEnd'),
  );

  Json toJson() => compact({
    'path': path,
    'dir': dir,
    'fileName': fileName,
    'title': title,
    'artist': artist,
    'albumArtist': albumArtist,
    'album': album,
    'trackNo': trackNo,
    'discNo': discNo == 0 ? null : discNo,
    'year': year == 0 ? null : year,
    'genre': genre,
    'composer': composer,
    'comment': comment,
    'codec': codec,
    'container': container,
    'sampleRate': sampleRate,
    'bitDepth': bitDepth,
    'channels': channels,
    'lossless': lossless,
    'dsd': dsd,
    'bitrate': bitrate,
    'durationMs': durationMs,
    'samples': samples,
    'sizeBytes': sizeBytes,
    'modTime': modTime,
    'cover': cover,
    'replayGain': replayGain == 0 ? null : replayGain,
    'favorite': favorite,
    'playCount': playCount,
    'lastPlayed': lastPlayed == 0 ? null : lastPlayed,
    'hasLyrics': hasLyrics,
    'cueFile': cueFile,
    'cueStart': cueStart == 0 ? null : cueStart,
    'cueEnd': cueEnd == 0 ? null : cueEnd,
  });

  Track copyWith({
    bool? favorite,
    int? playCount,
    int? lastPlayed,
    String? cover,
  }) => Track.fromJson(
    toJson()
      ..['favorite'] = favorite ?? this.favorite
      ..['playCount'] = playCount ?? this.playCount
      ..['lastPlayed'] = lastPlayed ?? this.lastPlayed
      ..['cover'] = cover ?? this.cover,
  );

  bool get isCue => cueFile.isNotEmpty;

  /// Title, or the file name without extension when untagged.
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final n = fileName.isNotEmpty ? fileName : _baseName(path);
    final dot = n.lastIndexOf('.');
    return dot > 0 ? n.substring(0, dot) : n;
  }

  /// Artist, falling back to album artist.
  String get displayArtist => artist.isNotEmpty ? artist : albumArtist;

  Duration get duration => Duration(milliseconds: durationMs);

  /// Upper-cased codec name as shown on a chip: "FLAC", "ALAC", "DSD".
  String get codecLabel {
    if (dsd) return 'DSD';
    final c = codec.toLowerCase();
    if (c.startsWith('pcm')) {
      return container.toLowerCase().contains('aif') ? 'AIFF' : 'WAV';
    }
    if (c == 'aac' && container.contains('m4a')) return 'AAC';
    if (c == 'vorbis') return 'OGG';
    return codec.toUpperCase();
  }

  /// "FLAC 24/96", "DSD64", "MP3 320", "AAC 256".
  String get formatBadge {
    if (dsd) return dsdLabel(_dsdRateOf(this));
    if (lossless || bitDepth > 0) {
      return '$codecLabel ${bitDepth > 0 ? '$bitDepth/' : ''}${sampleRateLabel(sampleRate)}';
    }
    return '$codecLabel${bitrate > 0 ? ' $bitrate' : ''}';
  }

  @override
  bool operator ==(Object other) => other is Track && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'Track($path)';
}

/// The engine reports DSD tracks with the PCM-equivalent sample rate (e.g.
/// 2822400/8 = 352800 for DSD64 as bytes per channel per second) or the raw
/// DSD rate; normalise both to a bit rate.
int _dsdRateOf(Track t) {
  final sr = t.sampleRate;
  if (sr >= 2000000) return sr; // already a bit rate
  if (sr > 0) return sr * 8; // bytes per second
  return 0;
}

String _baseName(String path) {
  final i = path.lastIndexOf(RegExp(r'[\\/]'));
  return i < 0 ? path : path.substring(i + 1);
}

/// Last path segment; exposed for tiles.
String baseName(String path) => _baseName(path);

/// A parsed .cue file.
class CueSheet {
  const CueSheet({
    required this.path,
    this.title = '',
    this.artist = '',
    this.file = '',
    this.tracks = const [],
  });

  final String path;
  final String title;
  final String artist;

  /// Referenced audio file.
  final String file;
  final List<Track> tracks;

  factory CueSheet.fromJson(Json j) => CueSheet(
    path: str(j, 'path'),
    title: str(j, 'title'),
    artist: str(j, 'artist'),
    file: str(j, 'file'),
    tracks: list(j, 'tracks', Track.fromJson),
  );

  Json toJson() => {
    'path': path,
    'title': title,
    'artist': artist,
    'file': file,
    'tracks': tracks.map((t) => t.toJson()).toList(),
  };
}

/// Content of one directory.
class Listing {
  const Listing({
    required this.dir,
    this.parent = '',
    this.dirs = const [],
    this.tracks = const [],
    this.cover = '',
    this.cue = const [],
  });

  final String dir;
  final String parent;
  final List<DirNode> dirs;
  final List<Track> tracks;
  final String cover;
  final List<CueSheet> cue;

  factory Listing.fromJson(Json j) => Listing(
    dir: str(j, 'dir'),
    parent: str(j, 'parent'),
    dirs: list(j, 'dirs', DirNode.fromJson),
    tracks: list(j, 'tracks', Track.fromJson),
    cover: str(j, 'cover'),
    cue: list(j, 'cue', CueSheet.fromJson),
  );

  Json toJson() => compact({
    'dir': dir,
    'parent': parent,
    'dirs': dirs.map((d) => d.toJson()).toList(),
    'tracks': tracks.map((t) => t.toJson()).toList(),
    'cover': cover,
    'cue': cue.isEmpty ? null : cue.map((c) => c.toJson()).toList(),
  });

  Duration get totalDuration =>
      Duration(milliseconds: tracks.fold(0, (a, t) => a + t.durationMs));
}

/// Tells clients what to refresh.
class LibraryChange {
  const LibraryChange({
    required this.dir,
    this.reason = '',
    this.removed = false,
  });

  final String dir;

  /// "fsnotify" | "scan" | "root".
  final String reason;
  final bool removed;

  factory LibraryChange.fromJson(Json j) => LibraryChange(
    dir: str(j, 'dir'),
    reason: str(j, 'reason'),
    removed: boolean(j, 'removed'),
  );

  Json toJson() => {'dir': dir, 'reason': reason, 'removed': removed};
}

/// Progress of an ongoing scan.
class ScanProgress {
  const ScanProgress({
    this.root = '',
    this.done = 0,
    this.total = 0,
    this.current = '',
    this.finished = false,
  });

  final String root;
  final int done;
  final int total;
  final String current;
  final bool finished;

  factory ScanProgress.fromJson(Json j) => ScanProgress(
    root: str(j, 'root'),
    done: integer(j, 'done'),
    total: integer(j, 'total'),
    current: str(j, 'current'),
    finished: boolean(j, 'finished'),
  );

  Json toJson() => {
    'root': root,
    'done': done,
    'total': total,
    'current': current,
    'finished': finished,
  };

  double get fraction => total == 0 ? 0 : done / total;
}

/// One playback in the history.
class HistoryEntry {
  const HistoryEntry({
    required this.track,
    this.playedAt = 0,
    this.complete = false,
  });

  final Track track;
  final int playedAt;
  final bool complete;

  factory HistoryEntry.fromJson(Json j) => HistoryEntry(
    track: Track.fromJson(obj(j, 'track') ?? const {}),
    playedAt: integer(j, 'playedAt'),
    complete: boolean(j, 'complete'),
  );

  Json toJson() => {
    'track': track.toJson(),
    'playedAt': playedAt,
    'complete': complete,
  };
}

/// An M3U playlist file.
class Playlist {
  const Playlist({required this.path, this.name = '', this.count = 0});

  final String path;
  final String name;
  final int count;

  factory Playlist.fromJson(Json j) => Playlist(
    path: str(j, 'path'),
    name: str(j, 'name'),
    count: integer(j, 'count'),
  );

  Json toJson() => {'path': path, 'name': name, 'count': count};
}

/// How to fetch a cover.
class CoverRef {
  const CoverRef({required this.hash, required this.url});

  final String hash;

  /// `/cover/{hash}.jpg`, relative to the engine HTTP port.
  final String url;

  factory CoverRef.fromJson(Json j) =>
      CoverRef(hash: str(j, 'hash'), url: str(j, 'url'));

  Json toJson() => {'hash': hash, 'url': url};
}

/// Sidecar or embedded lyrics; [lines] is non-empty for LRC.
class Lyrics {
  const Lyrics({this.text = '', this.lines = const [], this.source = ''});

  final String text;
  final List<LyricLine> lines;

  /// "lrc" | "txt" | "tag" | "".
  final String source;

  factory Lyrics.fromJson(Json j) => Lyrics(
    text: str(j, 'text'),
    lines: list(j, 'lines', LyricLine.fromJson),
    source: str(j, 'source'),
  );

  Json toJson() => compact({
    'text': text,
    'lines': lines.isEmpty ? null : lines.map((l) => l.toJson()).toList(),
    'source': source,
  });

  bool get isTimed => lines.isNotEmpty;
  bool get isEmpty => text.isEmpty && lines.isEmpty;

  /// Index of the line active at [ms], or -1 before the first.
  int activeIndex(int ms) {
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].ms <= ms) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }
}

/// One timed lyric line.
class LyricLine {
  const LyricLine({required this.ms, required this.text});

  final int ms;
  final String text;

  factory LyricLine.fromJson(Json j) =>
      LyricLine(ms: integer(j, 'ms'), text: str(j, 'text'));

  Json toJson() => {'ms': ms, 'text': text};
}
