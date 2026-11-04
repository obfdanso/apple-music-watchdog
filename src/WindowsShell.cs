// Windows shell helpers for the watchdog window: an app identity so the taskbar
// shows the watchdog's own icon (not PowerShell's), and shortcuts that start the
// watchdog without any console window. Compiled at runtime by WatchdogWindow.ps1
// via Add-Type, so it must stay within C# 5 (what Windows PowerShell 5.1 ships).
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

public static class WindowsShell {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SetCurrentProcessExplicitAppUserModelID(string appId);

    // Gives this process its own taskbar identity. Must be called before the window
    // is shown. Shortcuts saved with the same ID lend it their icon and name, and
    // pinning the window to the taskbar pins the shortcut.
    public static void SetAppId(string appId) {
        SetCurrentProcessExplicitAppUserModelID(appId);
    }

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);

    // Lets another process (the open watchdog window) bring itself to the front.
    // Windows only allows that when the process the user just started allows it.
    public static void AllowOthersToTakeFocus() {
        AllowSetForegroundWindow(-1);
    }

    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    class ShellLinkCo {}

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int max, IntPtr findData, uint flags);
        void GetIDList(out IntPtr idList);
        void SetIDList(IntPtr idList);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int max);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int max);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int max);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int showCmd);
        void SetShowCmd(int showCmd);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int max, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, uint reserved);
        void Resolve(IntPtr hwnd, uint flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, [Out] PropVariant value);
        void SetValue(ref PropertyKey key, [In] PropVariant value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    struct PropertyKey {
        public Guid FormatId;
        public uint PropertyId;
    }

    // Just enough of PROPVARIANT to pass a string (VT_LPWSTR).
    [StructLayout(LayoutKind.Explicit)]
    class PropVariant {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Pointer;
    }

    const ushort VtLpwstr = 31;
    static readonly Guid AppUserModelProperties = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

    // Saves a .lnk shortcut, tagged with the given taskbar identity.
    public static void SaveShortcut(string path, string target, string arguments, string workingDirectory,
                                    string iconPath, string description, string appId) {
        var link = (IShellLinkW)new ShellLinkCo();
        try {
            link.SetPath(target);
            link.SetArguments(arguments);
            link.SetWorkingDirectory(workingDirectory);
            link.SetIconLocation(iconPath, 0);
            link.SetDescription(description);

            var store = (IPropertyStore)link;
            var key = new PropertyKey { FormatId = AppUserModelProperties, PropertyId = 5 };
            var value = new PropVariant { Type = VtLpwstr, Pointer = Marshal.StringToCoTaskMemUni(appId) };
            try {
                store.SetValue(ref key, value);
                store.Commit();
            }
            finally {
                Marshal.FreeCoTaskMem(value.Pointer);
            }

            ((IPersistFile)link).Save(path, true);
        }
        finally {
            Marshal.ReleaseComObject(link);
        }
    }
}
