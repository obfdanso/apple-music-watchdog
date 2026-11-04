# Changelog

## Unreleased

- A window styled after the Apple Music app, in light or dark mode to match Windows. It shows the current song with its artwork, how far into it you are, a live waveform of the sound, and which device it's playing through, lets you change settings while the watchdog runs, and has a timer that can stop watching and pause Apple Music. It starts watching when you press Start Watching. Switches, buttons and page changes are animated. Double-clicking `watchdog.cmd` now opens it. Closing it stops the watchdog.
- The window adds an Apple Music Watchdog shortcut to the Start menu and the project folder. It opens the window with no console window, and the taskbar shows the watchdog's own icon.
- Starting in the background or at sign-in no longer flashes a console window.
- Optionally keeps running in the system tray when the window is closed.
- A choice of font for the window: the default, any installed font, or Anthropic Sans if you have it.
- Settings changed in the window are saved and used in the background too.
- Works when started from PowerShell 7 by handing over to Windows PowerShell 5.1.
- `watchdog stop` now lets the watchdog shut down cleanly and log that it stopped.
- The audio check uses about a sixth of the CPU it did.
- If the watchdog stops halfway through a fix, it presses play again instead of leaving the music paused.
- A bad value in the settings file no longer stops the watchdog from starting.
- An error in a window button or switch is logged instead of closing the watchdog.
- `watchdog stop` and `watchdog status` no longer mistake other PowerShell commands for the watchdog.
- The artwork shows up even when Apple Music sends it a moment after the song title.

## 0.1.0 - 2026-11-04

First release.

- Detects when Apple Music says it's playing but produces no sound, and pauses and resumes it.
- `watchdog.cmd` to start, stop, check status, and set up start at sign-in.
- Keeps the PC awake while music is playing.
- Log at `%LOCALAPPDATA%\AppleMusicWatchdog\watchdog.log`.
