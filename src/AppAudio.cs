// Reads per-app audio levels and which output device an app is playing through,
// using the Windows Core Audio API, and keeps the PC awake while music is playing. Compiled at runtime by AppleMusicWatchdog.ps1
// via Add-Type, so it must stay within C# 5 (what Windows PowerShell 5.1 ships).
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class AppAudio {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCo {}

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection {
        int GetCount(out int count);
        int Item(int index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IPropertyStore properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        int GetCount(out int count);
        int GetAt(int index, out PropertyKey key);
        int GetValue(ref PropertyKey key, out PropVariant value);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey {
        public Guid FormatId;
        public int PropertyId;
    }

    // Enough of PROPVARIANT to read a string or a number. Sized for 64-bit (24 bytes).
    [StructLayout(LayoutKind.Explicit)]
    struct PropVariant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
        [FieldOffset(8)] public uint Number;
        [FieldOffset(16)] public IntPtr Spare;
    }

    [DllImport("ole32.dll")]
    static extern int PropVariantClear(ref PropVariant value);

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
        var sessions = FindSessions(processNames);
        foreach (object session in sessions) {
            float peak;
            ((IAudioMeterInformation)session).GetPeakValue(out peak);
            if (peak > best) best = peak;
            Release(session);
        }
        return best;
    }

    // Reads the same level as GetPeak many times a second, cheaply: it holds on to
    // the sessions' level meters and only looks for sessions again every 2 seconds.
    // Used by the window's waveform. Must be used from one thread.
    public class LevelReader {
        readonly string[] processNames;
        List<object> sessions = new List<object>();
        DateTime refreshAt = DateTime.MinValue;

        public LevelReader(string[] processNames) {
            this.processNames = processNames;
        }

        public float Read() {
            if (DateTime.UtcNow >= refreshAt) {
                foreach (object session in sessions) Release(session);
                sessions = FindSessions(processNames);
                refreshAt = DateTime.UtcNow.AddSeconds(2);
            }
            float best = 0f;
            foreach (object session in sessions) {
                try {
                    float peak;
                    ((IAudioMeterInformation)session).GetPeakValue(out peak);
                    if (peak > best) best = peak;
                }
                catch {
                    refreshAt = DateTime.MinValue;   // the session went away; look again next time
                }
            }
            return best;
        }
    }

    // The audio sessions (as COM objects) owned by the named processes, on every
    // active output device. The caller must Release each one.
    static List<object> FindSessions(string[] processNames) {
        var found = new List<object>();
        var matches = new Dictionary<uint, bool>();
        object enumerator = null, devices = null;
        try {
            enumerator = new MMDeviceEnumeratorCo();
            IMMDeviceCollection deviceList;
            ((IMMDeviceEnumerator)enumerator).EnumAudioEndpoints(RenderFlow, DeviceStateActive, out deviceList);
            devices = deviceList;
            int deviceCount;
            deviceList.GetCount(out deviceCount);
            Guid iidManager = typeof(IAudioSessionManager2).GUID;
            for (int d = 0; d < deviceCount; d++) {
                IMMDevice device = null;
                object manager = null;
                IAudioSessionEnumerator sessions = null;
                try {
                    deviceList.Item(d, out device);
                    device.Activate(ref iidManager, ClsCtxAll, IntPtr.Zero, out manager);
                    ((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions);
                    int sessionCount;
                    sessions.GetCount(out sessionCount);
                    for (int i = 0; i < sessionCount; i++) {
                        IAudioSessionControl2 session = null;
                        bool keep = false;
                        try {
                            sessions.GetSession(i, out session);
                            uint pid;
                            session.GetProcessId(out pid);
                            bool match;
                            if (!matches.TryGetValue(pid, out match)) {
                                match = IsNamed(pid, processNames);
                                matches[pid] = match;
                            }
                            if (match) {
                                found.Add(session);
                                keep = true;
                            }
                        }
                        finally {
                            if (!keep) Release(session);
                        }
                    }
                }
                finally {
                    Release(sessions);
                    Release(manager);
                    Release(device);
                }
            }
        }
        finally {
            Release(devices);
            Release(enumerator);
        }
        return found;
    }

    // An output device, described for people.
    public class AudioOutput {
        public string Name;        // e.g. "oraimo Rover" or "Realtek(R) Audio"
        public string Kind;        // "Headphones", "Speakers", ...
        public string Connection;  // "Bluetooth", "USB", "Built-in", "HDMI or DisplayPort", "Network" or "External"
        public bool InUse;         // false when this is only the default device, with nothing playing through it
    }

    // The output devices the named processes are playing through right now. If
    // they aren't playing through any, the default output device (not in use).
    public static AudioOutput[] GetOutputs(string[] processNames) {
        var found = new List<AudioOutput>();
        var matches = new Dictionary<uint, bool>();
        object enumerator = null, devices = null;
        try {
            enumerator = new MMDeviceEnumeratorCo();
            IMMDeviceCollection deviceList;
            ((IMMDeviceEnumerator)enumerator).EnumAudioEndpoints(RenderFlow, DeviceStateActive, out deviceList);
            devices = deviceList;
            int deviceCount;
            deviceList.GetCount(out deviceCount);
            Guid iidManager = typeof(IAudioSessionManager2).GUID;
            for (int d = 0; d < deviceCount; d++) {
                IMMDevice device = null;
                object manager = null;
                IAudioSessionEnumerator sessions = null;
                try {
                    deviceList.Item(d, out device);
                    device.Activate(ref iidManager, ClsCtxAll, IntPtr.Zero, out manager);
                    ((IAudioSessionManager2)manager).GetSessionEnumerator(out sessions);
                    int sessionCount;
                    sessions.GetCount(out sessionCount);
                    bool inUse = false;
                    for (int i = 0; i < sessionCount && !inUse; i++) {
                        IAudioSessionControl2 session = null;
                        try {
                            sessions.GetSession(i, out session);
                            uint pid;
                            session.GetProcessId(out pid);
                            bool match;
                            if (!matches.TryGetValue(pid, out match)) {
                                match = IsNamed(pid, processNames);
                                matches[pid] = match;
                            }
                            int state;
                            session.GetState(out state);
                            inUse = match && state == SessionStateActive;
                        }
                        finally { Release(session); }
                    }
                    if (inUse) found.Add(Describe(device, true));
                }
                finally {
                    Release(sessions);
                    Release(manager);
                    Release(device);
                }
            }
            if (found.Count == 0) {
                IMMDevice fallback = null;
                try {
                    if (((IMMDeviceEnumerator)enumerator).GetDefaultAudioEndpoint(RenderFlow, RoleMultimedia, out fallback) == 0 && fallback != null) {
                        found.Add(Describe(fallback, false));
                    }
                }
                finally { Release(fallback); }
            }
        }
        finally {
            Release(devices);
            Release(enumerator);
        }
        return found.ToArray();
    }

    const int SessionStateActive = 1;
    const int RoleMultimedia = 1;
    static readonly Guid DeviceProperties = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
    static readonly Guid DeviceInterfaceProperties = new Guid("026e516e-b814-414b-83cd-856d6fef4822");
    static readonly Guid EndpointProperties = new Guid("1da5d803-d492-4edd-8c23-e0c0ffee7f0e");

    static AudioOutput Describe(IMMDevice device, bool inUse) {
        IPropertyStore store = null;
        try {
            device.OpenPropertyStore(0, out store);
            // "oraimo Rover", falling back to the endpoint's full name, "Headphones (oraimo Rover)".
            string name = ReadText(store, DeviceInterfaceProperties, 2);
            if (string.IsNullOrEmpty(name)) name = ReadText(store, DeviceProperties, 14) ?? "Unknown device";
            uint formFactor = ReadNumber(store, EndpointProperties, 0, 10);
            string bus = (ReadText(store, DeviceProperties, 24) ?? "").ToUpperInvariant();

            var output = new AudioOutput { Name = name, InUse = inUse };
            switch (formFactor) {
                case 0: output.Kind = "Network device"; break;
                case 1: output.Kind = "Speakers"; break;
                case 2: output.Kind = "Line out"; break;
                case 3: output.Kind = "Headphones"; break;
                case 5: output.Kind = "Headset"; break;
                case 8: output.Kind = "Digital output"; break;
                case 9: output.Kind = "Display"; break;
                default: output.Kind = "Audio device"; break;
            }
            if (bus.StartsWith("BTH")) output.Connection = "Bluetooth";
            else if (bus.StartsWith("USB")) output.Connection = "USB";
            else if (formFactor == 9) output.Connection = "HDMI or DisplayPort";
            else if (formFactor == 0) output.Connection = "Network";
            else if (bus == "HDAUDIO" || bus == "INTELAUDIO" || bus.StartsWith("ACPI") || bus.StartsWith("SNDW")) output.Connection = "Built-in";
            else output.Connection = "External";
            return output;
        }
        finally { Release(store); }
    }

    static string ReadText(IPropertyStore store, Guid format, int id) {
        var key = new PropertyKey { FormatId = format, PropertyId = id };
        PropVariant value;
        if (store.GetValue(ref key, out value) != 0) return null;
        try { return value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : null; }   // VT_LPWSTR
        finally { PropVariantClear(ref value); }
    }

    static uint ReadNumber(IPropertyStore store, Guid format, int id, uint fallback) {
        var key = new PropertyKey { FormatId = format, PropertyId = id };
        PropVariant value;
        if (store.GetValue(ref key, out value) != 0) return fallback;
        try { return value.Type == 19 ? value.Number : fallback; }                       // VT_UI4
        finally { PropVariantClear(ref value); }
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inheritHandle, uint pid);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder name, ref uint size);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    const uint ProcessQueryLimitedInformation = 0x1000;

    // Whether the process has one of the given names (without ".exe"). Asks
    // Windows about this one process only, which is much cheaper than listing
    // every running process.
    static bool IsNamed(uint pid, string[] processNames) {
        IntPtr handle = OpenProcess(ProcessQueryLimitedInformation, false, pid);
        if (handle == IntPtr.Zero) return false;
        try {
            var path = new StringBuilder(1024);
            uint size = (uint)path.Capacity;
            if (!QueryFullProcessImageName(handle, 0, path, ref size)) return false;
            string name = Path.GetFileNameWithoutExtension(path.ToString());
            return Array.Exists(processNames, x => x.Equals(name, StringComparison.OrdinalIgnoreCase));
        }
        finally { CloseHandle(handle); }
    }

    // Free a COM object now instead of waiting for the garbage collector, since
    // GetPeak runs every second for as long as the watchdog is running.
    static void Release(object o) {
        if (o != null && Marshal.IsComObject(o)) Marshal.ReleaseComObject(o);
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
