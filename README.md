# Apple Music Watchdog

[![Lint](https://github.com/obfdanso/apple-music-watchdog/actions/workflows/lint.yml/badge.svg)](https://github.com/obfdanso/apple-music-watchdog/actions/workflows/lint.yml)

Keeps Apple Music for Windows playing when it goes quiet on a shaky internet connection.

## The problem

When your connection drops for a moment, the Apple Music app on Windows can get stuck: the song still shows as playing and the progress bar may keep moving, but no sound comes out. Pausing and pressing play again brings the audio back. If you're asleep, at work, or across the room, nobody is there to press it, so the music just stops.

## What this does

A small script keeps an eye on Apple Music, either in a window or quietly in the background. If the app says it's playing but no sound has come out of it for 12 seconds in a row, the script pauses and resumes playback for you, the same fix you'd do by hand.

- It only touches Apple Music. Other apps playing or paused in the background are left alone.
- The gap between songs and quiet intros are shorter than 12 seconds, so they don't set it off.
- If the connection is down for a long time, it waits at least 20 seconds between attempts.
- While Apple Music is playing, it stops the PC from going to sleep. Otherwise sleep works as normal.
- It logs each fix so you can see in the morning what happened.

It works with any speakers or headphones (Bluetooth, USB or built-in), because it measures the sound Apple Music produces, not the output device.

## Requirements

- Windows 10 or 11
- The [Apple Music app](https://apps.microsoft.com/detail/9pfhdd62mxs1) from the Microsoft Store
- Windows PowerShell 5.1, which comes with Windows. Nothing to install. If you use PowerShell 7, that works too: the scripts hand themselves over to 5.1, because PowerShell 7 can't load the Windows media controls they need.

## Quick start

1. Download this project: [download the ZIP](https://github.com/obfdanso/apple-music-watchdog/archive/refs/heads/main.zip) and extract it, or run
   `git clone https://github.com/obfdanso/apple-music-watchdog.git`
2. Start playing something in Apple Music.
3. Double-click **`watchdog.cmd`**. The watchdog window opens.
4. Press **Start Watching**.

That's it. It watches Apple Music until you press **Stop Watching** or close the window.

The first time the window opens, it adds an **Apple Music Watchdog** shortcut to the project folder and to your Start menu. Use that from then on. It opens the window straight away, without the console window that briefly appears when you double-click `watchdog.cmd`.

If you'd rather not have a window, run `watchdog start` instead and it runs in the background until you stop it or restart your PC. To have it start in the background every time you sign in to Windows, open a terminal in the project folder and run:

```
watchdog install
```

## The window

The window is styled after the Apple Music app and follows your Windows light or dark mode. Along the top you'll see whether it's watching, the current song with its artwork and how far into it you are, and a **Start Watching** / **Stop Watching** button. It doesn't start watching until you press that button. The sidebar has two pages:

- **Now Playing:** the song and artwork, a live waveform of the sound coming out of Apple Music, and what the watchdog is doing about it, such as "No sound for 5 sec. Pausing and playing at 12 sec." Below that, how many times it has fixed the music and whether the sound came back the last time, how long it has been watching, the timer, and which device the music is playing through (for example "oraimo Rover, Bluetooth headphones" or "This PC's speakers").
- **Settings:** how long the music can be silent before it pauses and plays, how long to wait before trying again, the timer (see below), whether to keep the PC awake while music plays, the window's font, and whether closing the window hides it in the tray. Changes take effect straight away.

For the **timer**, turn on **Stop after a set time** in Settings and pick a duration, or tap one of the presets (15 minutes to 4 hours). The countdown starts when you press **Start Watching**. When the time is up it stops watching and, unless you turn that off, pauses Apple Music.

Every fix is also written to the log (see [The log](#the-log)).

Closing the window stops the watchdog. If you'd rather it kept going, turn on **Keep running in the tray when closed** in Settings. Then the close button hides the window in the system tray, off the taskbar, and the watchdog keeps working. Click the tray icon to bring the window back, or right-click it to start or stop watching or to quit. Opening the shortcut again also brings the window back.

For the font there are three choices: **Default** (Segoe UI Variable), **System font** (any font installed on your PC, picked from a searchable list) and **Anthropic Sans**. Anthropic Sans isn't included because it isn't freely licensed. If you have it, install it, or put its font files in the [`fonts`](fonts) folder.

If the watchdog was already running in the background, opening the window takes over from it. Your settings are remembered for next time.

## Commands

Run these from a terminal (Command Prompt or PowerShell) in the project folder. Double-clicking `watchdog.cmd` is the same as `watchdog ui`.

| Command              | What it does                                             |
| -------------------- | -------------------------------------------------------- |
| `watchdog ui`        | Open the window                                          |
| `watchdog start`     | Start the watchdog in the background, without a window   |
| `watchdog stop`      | Stop it                                                  |
| `watchdog restart`   | Stop and start again                                     |
| `watchdog status`    | Show whether it's running and the latest log entries     |
| `watchdog check`     | Show Apple Music's status and sound level for 5 seconds  |
| `watchdog install`   | Start it automatically when you sign in to Windows       |
| `watchdog uninstall` | Stop starting it at sign-in, and remove its shortcuts    |
| `watchdog log`       | Open the log file                                        |

In PowerShell, type `.\watchdog` instead of `watchdog`.

## Checking that it works on your PC

Play a song and run `watchdog check`. You should see something like:

```
02:30:53  status=Playing  level=0.4752
02:30:54  status=Playing  level=0.2321
```

If `level` stays at `0.0000` while you can clearly hear music, detection isn't working on your setup. Please [open an issue](https://github.com/obfdanso/apple-music-watchdog/issues) with the output.

## The log

Every fix is written to `%LOCALAPPDATA%\AppleMusicWatchdog\watchdog.log`:

```
2026-11-04 03:12:40  Silent for 12s while 'Playing' ('Some Song'). Pausing and resuming (fix #1).
2026-11-04 03:12:45  After resume: level=0.3821
```

A level above zero after the resume means the sound came back. A zero usually means the connection was still down or the song was still buffering. If it stays silent, the watchdog tries again after the cooldown. The log rolls over at 1 MB.

## Settings

The defaults suit most people. The easiest way to change them is in the window. They're saved to `%LOCALAPPDATA%\AppleMusicWatchdog\settings.json` and used in the background too (restart it with `watchdog restart` to pick up changes).

You can also give them when running the script directly. These win over the saved settings:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\src\AppleMusicWatchdog.ps1 -SilentSeconds 20 -CooldownSeconds 30
```

| Setting            | Default | Meaning                                                           |
| ------------------ | ------- | ----------------------------------------------------------------- |
| `-SilentSeconds`   | 12      | Seconds of silence while "Playing" before it steps in             |
| `-CooldownSeconds` | 20      | Minimum seconds between fixes                                     |
| `-Threshold`       | 0.0005  | Sound level (0 to 1) that counts as silence                       |
| `-AllowSleep`      | off     | Let the PC sleep even while music is playing                      |
| `-LogPath`         | see above | Where to write the log                                          |

## Good to know

- **Laptop lid:** keeping the PC awake doesn't stop it sleeping when you close the lid. If you want music with the lid shut, set "When I close the lid" to "Do nothing" in Windows power settings.
- **Restarts:** after a restart it only comes back on its own if you ran `watchdog install`.
- **Console window:** Windows always opens a console window for a moment when you double-click a `.cmd` file. The **Apple Music Watchdog** shortcut doesn't, and neither does the watchdog when it starts in the background or at sign-in.
- **Taskbar:** the window shows up on the taskbar with its own icon. If you pin it, the pin opens the window the same way the shortcut does.

## How it works

- **Is Apple Music playing?** Windows exposes each media app's playback state through its media controls (the same ones behind your keyboard's play/pause key). The script reads Apple Music's state there and uses the same controls to pause and play.
- **Is any sound coming out?** The Windows Core Audio API reports a live level meter for each app's audio stream. Apple Music sends its sound through a helper process called `AMPLibraryAgent.exe`, so that's the stream the script measures.

The code is in [`src/AppleMusicWatchdog.ps1`](src/AppleMusicWatchdog.ps1) (main loop), [`src/WatchdogWindow.ps1`](src/WatchdogWindow.ps1) (the window), [`src/AppAudio.cs`](src/AppAudio.cs) (audio meter and output device), [`src/WindowsShell.cs`](src/WindowsShell.cs) (taskbar icon and shortcuts) and [`src/Waveform.cs`](src/Waveform.cs) (the waveform), with [`src/Manage.ps1`](src/Manage.ps1) behind the `watchdog` commands.

## Uninstalling

```
watchdog uninstall
watchdog stop
```

`watchdog uninstall` also removes the Start menu shortcut. Then delete the folder, and `%LOCALAPPDATA%\AppleMusicWatchdog` if you want the log, saved settings and icon gone too.

## Contributing

Bug reports and pull requests are welcome. If detection doesn't work for you, the output of `watchdog check` and your Windows and Apple Music versions help a lot.

## License

[MIT](LICENSE)

This project isn't affiliated with or endorsed by Apple. Apple Music is a trademark of Apple Inc.
