# Apple Music Watchdog

Keeps Apple Music for Windows playing when it goes quiet on a shaky internet connection.

## The problem

When your connection drops for a moment, the Apple Music app on Windows can get stuck: the song still shows as playing and the progress bar may keep moving, but no sound comes out. Pausing and pressing play again brings the audio back. If you're asleep, at work, or across the room, nobody is there to press it, so the music just stops.

## What this does

A small background script checks Apple Music once a second. If the app says it's playing but no sound has come out of it for 12 seconds in a row, the script pauses and resumes playback for you, the same fix you'd do by hand.

- It only touches Apple Music. Other apps playing or paused in the background are left alone.
- The gap between songs and quiet intros are shorter than 12 seconds, so they don't set it off.
- If the connection is down for a long time, it waits at least 20 seconds between attempts.
- While Apple Music is playing, it stops the PC from going to sleep. Otherwise sleep works as normal.
- It logs each fix so you can see in the morning what happened.

It works with any speakers or headphones (Bluetooth, USB or built-in), because it measures the sound Apple Music produces, not the output device.

## Requirements

- Windows 10 or 11
- The [Apple Music app](https://apps.microsoft.com/detail/9pfhdd62mxs1) from the Microsoft Store
- Windows PowerShell 5.1, which comes with Windows. Nothing to install.

## Quick start

1. Download this project: click **Code → Download ZIP** on GitHub and extract it, or run
   `git clone https://github.com/<your-username>/apple-music-watchdog.git`
2. Start playing something in Apple Music.
3. Double-click **`watchdog.cmd`**.

That's it. It now runs in the background until you stop it or restart your PC.

To have it start every time you sign in to Windows, open a terminal in the project folder and run:

```
watchdog install
```

## Commands

Run these from a terminal (Command Prompt or PowerShell) in the project folder. Double-clicking `watchdog.cmd` is the same as `watchdog start`.

| Command              | What it does                                             |
| -------------------- | -------------------------------------------------------- |
| `watchdog start`     | Start the watchdog in the background                     |
| `watchdog stop`      | Stop it                                                  |
| `watchdog restart`   | Stop and start again                                     |
| `watchdog status`    | Show whether it's running and the latest log entries     |
| `watchdog check`     | Show Apple Music's status and sound level for 5 seconds  |
| `watchdog install`   | Start it automatically when you sign in to Windows       |
| `watchdog uninstall` | Stop starting it at sign-in                              |
| `watchdog log`       | Open the log file                                        |

In PowerShell, type `.\watchdog` instead of `watchdog`.

## Checking that it works on your PC

Play a song and run `watchdog check`. You should see something like:

```
02:30:53  status=Playing  level=0.4752
02:30:54  status=Playing  level=0.2321
```

If `level` stays at `0.0000` while you can clearly hear music, detection isn't working on your setup. Please [open an issue](../../issues) with the output.

## The log

Every fix is written to `%LOCALAPPDATA%\AppleMusicWatchdog\watchdog.log`:

```
2026-11-04 03:12:40  Silent for 12s while 'Playing' ('Some Song'). Pausing and resuming (fix #1).
2026-11-04 03:12:45  After resume: level=0.3821
```

A level above zero after the resume means the sound came back. A zero usually means the connection was still down or the song was still buffering. If it stays silent, the watchdog tries again after the cooldown. The log rolls over at 1 MB.

## Settings

The defaults suit most people. To change them, run the script directly:

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
- **Brief console flash:** with autostart on, a console window may flash for a moment when you sign in. That's Windows starting the hidden script.

## How it works

- **Is Apple Music playing?** Windows exposes each media app's playback state through its media controls (the same ones behind your keyboard's play/pause key). The script reads Apple Music's state there and uses the same controls to pause and play.
- **Is any sound coming out?** The Windows Core Audio API reports a live level meter for each app's audio stream. Apple Music sends its sound through a helper process called `AMPLibraryAgent.exe`, so that's the stream the script measures.

The code is in [`src/AppleMusicWatchdog.ps1`](src/AppleMusicWatchdog.ps1) (main loop) and [`src/AppAudio.cs`](src/AppAudio.cs) (audio meter), with [`src/Manage.ps1`](src/Manage.ps1) behind the `watchdog` commands.

## Uninstalling

```
watchdog uninstall
watchdog stop
```

Then delete the folder, and `%LOCALAPPDATA%\AppleMusicWatchdog` if you want the log gone too.

## Contributing

Bug reports and pull requests are welcome. If detection doesn't work for you, the output of `watchdog check` and your Windows and Apple Music versions help a lot.

## License

[MIT](LICENSE)

This project isn't affiliated with or endorsed by Apple. Apple Music is a trademark of Apple Inc.
