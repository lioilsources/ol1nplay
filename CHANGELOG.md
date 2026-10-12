# Changelog

## 0.2.0

First release shaped by a real Windows 11 / ASIO listener.

- **Mono through one speaker.** The mono switch is now Stereo · Mono · L · R.
  L and R play the same downmix through the left or the right speaker only,
  for comparing cables or components side against side. On the desktop
  (`M` cycles) and, with large buttons, on the remote's Now playing screen.
- **Seek bar with the track's loudness.** A strip across the whole desktop
  window, and on the remote, draws the track end to end; quiet passages are
  visible and one click away.
- **Black appearance** next to Dark and Light (Settings → Appearance, also
  on the remote).
- **Favorites in the album.** The heart on a track row now fills in at once
  (on the desktop it used to wait until the folder was reopened), and a
  heart button in the folder header shows only the hearted tracks — playing
  from that view plays just those.
- **Rituals** (Settings, all off by default): lock decoded audio in RAM, a
  0–8 s "memory cooltime" before a start from silence, and a helper program
  — for instance MinorityClean — started and stopped with the engine. See
  the README for what these do and do not change.
- **Fixed: closing PowerShell closed the player.** A player started from a
  terminal no longer shares its console.
- **No Visual C++ Redistributable needed.** The runtime DLLs ship in the
  zip. `install.ps1` installs to `%LOCALAPPDATA%\Programs` and adds Start
  menu and desktop shortcuts.
- New icon.

## 0.1.0

First public build: Windows player (engine + desktop UI) and Android remote.
