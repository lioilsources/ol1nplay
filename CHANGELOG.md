# Changelog

## 0.2.1

From the same listener's second round, still on Windows 11 / ASIO.

- **L and R no longer need Mono.** The switch is now three buttons, Mono ·
  L · R. L or R alone plays that channel's own signal and mutes the other;
  with Mono on they play the downmix through one speaker, as before. `M`
  toggles Mono.
- **Fixed: music kept playing after the player was gone.** An engine the
  app started now shuts down when the app exits, however it exits. (An
  engine you start yourself is left alone.)
- **One click plays a track** in the folder view. Ctrl- or Shift-click
  still only selects.
- **Fixed: the heart did not fill in the Queue tab.** The queue now follows
  a heart set anywhere.
- **ASIO: tracks at a different sample rate failing to start.** The engine
  gave up when the driver had not switched rate the instant it was asked;
  it now waits up to two seconds for the new rate and retries a refused
  request. This is the likely reason some FLACs played at one time and not
  at another, but it has not been confirmed on the affected machine.
- **`engine.log`** in the data folder (`%LOCALAPPDATA%\Ol1nPlay`) records
  what the log drawer shows, so a track that would not play can be looked
  into afterwards.
- The loudness seek bar is drawn as a continuous waveform.

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
