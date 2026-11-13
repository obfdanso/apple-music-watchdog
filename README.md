# Apple Music Watchdog

[![Lint](https://github.com/obfdanso/apple-music-watchdog/actions/workflows/lint.yml/badge.svg)](https://github.com/obfdanso/apple-music-watchdog/actions/workflows/lint.yml)

Keeps Apple Music for Windows playing when it goes quiet on a shaky internet connection.

## The problem

When your connection drops for a moment, the Apple Music app on Windows can get stuck: the song still shows as playing and the progress bar may keep moving, but no sound comes out. Pausing and pressing play again brings the audio back. If you're asleep, at work, or across the room, nobody is there to press it, so the music just stops.

## What this does

A small script keeps an eye on Apple Music, either in a window or quietly in the background. If the app says it's playing but no sound has come out of it for 12 seconds in a row, the script pauses and resumes playback for you, the same fix you'd do by hand.

- It only touches Apple Music. Other apps playing or paused in the background are left alone.
- The gap between songs and quiet intros are shorter than 12 seconds, so they don't set it off.
- If pausing and playing twice doesn't bring the sound back, it restarts the song, then skips to the next one. As a last resort it closes Apple Music, opens it again and presses play (at most once every half hour, and you can turn that off).
- Before each fix it checks that Apple Music's servers can be reached. If the internet is down, it waits for it to come back instead of pausing and playing over and over, then fixes the sound straight away. Between attempts it waits at least 20 seconds.
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

If you'd rather not have a window, run `watchdog start` instead and it runs in the background until you stop it or restart your PC. To have it start in the background every time you sign in to Windows, turn on **Start when I sign in** in the window's Settings, or open a terminal in the project folder and run:

```
watchdog install
```

## The window

The window is styled after the Apple Music app and follows your Windows light or dark mode. Along the top you'll see whether it's watching, previous, play/pause and next buttons that control Apple Music, the current song with its artwork and how far into it you are, and a **Start Watching** / **Stop Watching** button. It doesn't start watching until you press that button. The sidebar has two pages:

- **Now Playing:** the song and artwork, a live waveform of the sound coming out of Apple Music, and what the watchdog is doing about it, such as "No sound for 5 sec. Pausing and playing at 12 sec." or "Waiting for the internet to come back". Below that, how many times it has fixed the music, how long it has been watching, the timer, the last fix (what it did, during which song, when, and whether the sound came back), and which device the music is playing through (for example "oraimo Rover, Bluetooth headphones" or "This PC's speakers").
- **Settings:** how long the music can be silent before it pauses and plays, how long to wait before trying again, whether to restart Apple Music as a last resort, **Stay paused when I pause** (see below), notifications, the timer, whether to keep the PC awake while music plays, the window's font, whether to start at sign-in, and whether closing the window hides it in the tray. Changes take effect straight away.

For the **timer**, turn on **Stop after a set time** in Settings and pick a duration, or tap one of the presets (15 minutes to 4 hours). The countdown starts when you press **Start Watching**. When the time is up it stops watching and, unless you turn that off, pauses Apple Music. With **Fade out first** on, it turns Apple Music down slowly over the last 30 seconds before pausing, then puts the volume back.

The watchdog only fixes songs that Apple Music says are playing, so a song you pause is left alone. The one exception: if Apple Music stops while the internet is down, the watchdog presses play once the connection is back, because it can't tell whether you paused it or Apple Music gave up. Turn on **Stay paused when I pause** and it never presses play on paused music.

With **Notifications** on (the default), Windows shows a silent notification when the internet drops out, when it took more than pausing and playing to get the sound back (for example "Skipped to the next song"), or when nothing worked. They show up once the window has been opened at least once, since Windows needs the Start menu shortcut it adds.

Every fix is also written to the log (see [The log](#the-log)).

Closing the window stops the watchdog. If you'd rather it kept going, turn on **Keep running in the tray when closed** in Settings. Then the close button hides the window in the system tray, off the taskbar, and the watchdog keeps working. Click the tray icon to bring the window back, or right-click it to see the current song, play, pause or skip, start or stop watching, or quit. Opening the shortcut again also brings the window back.

For the font there are two choices: **Default** (Segoe UI Variable) and **System font** (any font installed on your PC, picked from a searchable list). To use a font without installing it, put its files in the [`fonts`](fonts) folder.

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
2026-11-04 04:20:02  Silent, and Apple Music can't be reached. Waiting for the connection to come back.
2026-11-04 04:21:37  The connection is back after 95s
2026-11-04 04:21:37  Still silent after the connection came back ('Other Song'). Pausing and resuming (fix #2).
```

A level above zero after the resume means the sound came back. A zero usually means the song was still buffering. If it stays silent, the watchdog tries its next fix after the cooldown. The log rolls over at 1 MB.

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
| `-CheckHost`       | `amp-api.music.apple.com` | Server it connects to, to check the internet before a fix |

## Good to know

- **Laptop lid:** keeping the PC awake doesn't stop it sleeping when you close the lid. If you want music with the lid shut, set "When I close the lid" to "Do nothing" in Windows power settings.
- **Restarts:** after a restart it only comes back on its own if you turned on **Start when I sign in** (or ran `watchdog install`).
- **Restarting Apple Music:** when the watchdog restarts Apple Music as a last resort, Apple Music may not pick up exactly where it left off and can start a different song.
- **Console window:** Windows always opens a console window for a moment when you double-click a `.cmd` file. The **Apple Music Watchdog** shortcut doesn't, and neither does the watchdog when it starts in the background or at sign-in.
- **Taskbar:** the window shows up on the taskbar with its own icon. If you pin it, the pin opens the window the same way the shortcut does.

## How it works

- **Is Apple Music playing?** Windows exposes each media app's playback state through its media controls (the same ones behind your keyboard's play/pause key). The script reads Apple Music's state there and uses the same controls to pause and play.
- **Is any sound coming out?** The Windows Core Audio API reports a live level meter for each app's audio stream. Apple Music sends its sound through a helper process called `AMPLibraryAgent.exe`, so that's the stream the script measures. The same API sets Apple Music's volume in the Windows volume mixer for the timer's fade-out.
- **Is the internet working?** Before a fix, it tries to connect to one of Apple Music's servers. If that fails, pausing and playing can't help, so it waits and tries again every 5 seconds.

The code is in [`src/AppleMusicWatchdog.ps1`](src/AppleMusicWatchdog.ps1) (main loop), [`src/WatchdogWindow.ps1`](src/WatchdogWindow.ps1) (the window), [`src/AppAudio.cs`](src/AppAudio.cs) (audio meter, volume and output device), [`src/WindowsShell.cs`](src/WindowsShell.cs) (taskbar icon and shortcuts), [`src/Waveform.cs`](src/Waveform.cs) (the waveform), [`src/SmoothScroll.cs`](src/SmoothScroll.cs) (smooth scrolling) and [`src/Autostart.ps1`](src/Autostart.ps1) (starting at sign-in), with [`src/Manage.ps1`](src/Manage.ps1) behind the `watchdog` commands.

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
