/// Wire command and event names. Mirrors `engine/protocol/protocol.go`
/// (`Cmd*` and `Ev*` constants) 1:1 — keep both in sync.
library;

/// Protocol version this package speaks.
const int protocolVersion = 1;

/// Request types (`Request.type`).
abstract final class Cmd {
  static const hello = 'hello';
  static const state = 'state';

  static const libraryRoots = 'library.roots';
  static const libraryRootAdd = 'library.roots.add';
  static const libraryRootRemove = 'library.roots.remove';
  static const libraryRescan = 'library.rescan';
  static const libraryList = 'library.list';
  static const libraryTree = 'library.tree';
  static const librarySearch = 'library.search';
  static const libraryTrack = 'library.track';

  static const play = 'play';
  static const pause = 'pause';
  static const resume = 'resume';
  static const toggle = 'toggle';
  static const stop = 'stop';
  static const next = 'next';
  static const prev = 'prev';
  static const seek = 'seek';
  static const mono = 'mono';
  static const repeat = 'repeat';
  static const shuffle = 'shuffle';

  static const abSetA = 'ab.setA';
  static const abSetB = 'ab.setB';
  static const abClear = 'ab.clear';
  static const abNudge = 'ab.nudge';
  static const abToggle = 'ab.toggle';

  static const queueGet = 'queue.get';
  static const queueSet = 'queue.set';
  static const queueAdd = 'queue.add';
  static const queueInsert = 'queue.insert';
  static const queueRemove = 'queue.remove';
  static const queueMove = 'queue.move';
  static const queueClear = 'queue.clear';
  static const queueJump = 'queue.jump';

  static const devices = 'devices';
  static const deviceSelect = 'device.select';
  static const outputStats = 'output.stats';
  static const outputReset = 'output.reset';

  static const sysmodeGet = 'sysmode.get';
  static const sysmodeSet = 'sysmode.set';
  static const sysmodeApply = 'sysmode.apply';
  static const sysmodeRestore = 'sysmode.restore';
  static const sysmodeLog = 'sysmode.log';

  static const remoteInfo = 'remote.info';
  static const remoteEnable = 'remote.enable';
  static const remoteRotate = 'remote.rotate';

  static const favorites = 'favorites';
  static const favoriteAdd = 'favorites.add';
  static const favoriteRemove = 'favorites.remove';
  static const history = 'history';
  static const playlists = 'playlists';
  static const playlistLoad = 'playlist.load';
  static const playlistSave = 'playlist.save';
  static const sleepSet = 'sleep.set';
  static const sleepClear = 'sleep.clear';
  static const settingsGet = 'settings.get';
  static const settingsSet = 'settings.set';
  static const lyrics = 'lyrics';
  static const waveform = 'waveform';
  static const cover = 'cover';
  static const version = 'version';
  static const shutdown = 'shutdown';
}

/// Event types (`Event.type`).
abstract final class Ev {
  static const state = 'state';
  static const queue = 'queue';
  static const libraryChanged = 'library.changed';
  static const libraryScan = 'library.scan';
  static const log = 'log';
  static const sysmode = 'sysmode';
  static const output = 'output';
  static const error = 'error';
  static const sleep = 'sleep';

  /// Every response to a request carries this type.
  static const result = 'result';
}

/// Playback states (`State.playback`).
abstract final class Playback {
  static const stopped = 'stopped';
  static const playing = 'playing';
  static const paused = 'paused';
  static const loading = 'loading';
}

/// Repeat modes (`State.repeat`).
abstract final class Repeat {
  static const off = 'off';
  static const one = 'one';
  static const all = 'all';

  static const values = [off, one, all];

  /// Cycles off → all → one → off, which is what the transport button does.
  static String nextOf(String mode) => switch (mode) {
    off => all,
    all => one,
    _ => off,
  };
}

/// Output device status (`Output.status`).
abstract final class OutputStatus {
  static const closed = 'closed';
  static const open = 'open';
  static const running = 'running';
  static const error = 'error';
}
