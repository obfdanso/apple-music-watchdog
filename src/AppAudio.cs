// Reads per-app audio levels through the Windows Core Audio API, and keeps the
// PC awake while music is playing. Compiled at runtime by AppleMusicWatchdog.ps1
// via Add-Type, so it must stay within C# 5 (what Windows PowerShell 5.1 ships).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

public static class AppAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
    }

    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionManager2 {
        int GetAudioSessionControl(IntPtr sessionGuid, int flags, out IntPtr control);
        int GetSimpleAudioVolume(IntPtr sessionGuid, int flags, out IntPtr volume);
        int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
    }

    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionEnumerator {
        int GetCount(out int count);
        int GetSession(int index, out IAudioSessionControl2 session);
    }

    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioSessionControl2 {
        int GetState(out int state);
        int GetDisplayName(out IntPtr name);
        int SetDisplayName(string name, ref Guid ctx);
        int GetIconPath(out IntPtr path);
        int SetIconPath(string path, ref Guid ctx);
        int GetGroupingParam(out Guid param);
        int SetGroupingParam(ref Guid param, ref Guid ctx);
        int RegisterAudioSessionNotification(IntPtr client);
        int UnregisterAudioSessionNotification(IntPtr client);
        int GetSessionIdentifier(out IntPtr id);
        int GetSessionInstanceIdentifier(out IntPtr id);
        int GetProcessId(out uint pid);
    }

    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioMeterInformation {
        int GetPeakValue(out float peak);
    }

    const int RenderFlow = 0;
    const int DeviceStateActive = 1;
    const int ClsCtxAll = 23;

    // Highest current peak level (0..1) across all audio sessions owned by the
    // named processes, on every active output device. Returns -1 if none of
    // those processes has an audio session open.
    public static float GetPeak(string[] processNames) {
        float best = -1f;
        var names = new Dictionary<uint, string>();
        var enumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorCo());
        IMMDeviceCollection devices;
        enumerator.EnumAudioEndpoints(RenderFlow, DeviceStateActive, out devices);
        int deviceCount;
        devices.GetCount(out deviceCount);
        Guid iidManager = typeof(IAudioSessionManager2).GUID;
        for (int d = 0; d < deviceCount; d++) {
            IMMDevice device;
            devices.Item(d, out device);
            object o;
            device.Activate(ref iidManager, ClsCtxAll, IntPtr.Zero, out o);
            IAudioSessionEnumerator sessions;
            ((IAudioSessionManager2)o).GetSessionEnumerator(out sessions);
            int sessionCount;
            sessions.GetCount(out sessionCount);
            for (int i = 0; i < sessionCount; i++) {
                IAudioSessionControl2 session;
                sessions.GetSession(i, out session);
                uint pid;
                session.GetProcessId(out pid);
                string name;
                if (!names.TryGetValue(pid, out name)) {
                    try { name = Process.GetProcessById((int)pid).ProcessName; } catch { name = ""; }
                    names[pid] = name;
                }
                if (Array.FindIndex(processNames, x => x.Equals(name, StringComparison.OrdinalIgnoreCase)) < 0) continue;
                float peak;
                ((IAudioMeterInformation)session).GetPeakValue(out peak);
                if (peak > best) best = peak;
            }
        }
        return best;
    }

    [DllImport("kernel32.dll")]
    static extern uint SetThreadExecutionState(uint flags);

    const uint EsContinuous = 0x80000000u;
    const uint EsSystemRequired = 0x00000001u;

    // While on, Windows won't go to sleep from idle (the screen can still turn off).
    // Must be called from the same thread each time; PowerShell's main loop is.
    public static void SetKeepAwake(bool on) {
        SetThreadExecutionState(on ? EsContinuous | EsSystemRequired : EsContinuous);
    }
}
