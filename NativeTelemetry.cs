using System;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public sealed class PanelSystemInfo {
    public double? CpuPercent;
    public double MemoryUsedGB, MemoryTotalGB;
    public uint MemoryPercent;
}
public sealed class PanelGpuInfo {
    public string Name;
    public uint? Utilization, FanPercent;
    public double? MemoryUsedGB, MemoryTotalGB, PowerWatts;
}
public static class PanelNative {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    public static void SetAppIdentity() {
        SetCurrentProcessExplicitAppUserModelID("HWiNFO.DesktopPanel");
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
    private static extern int RegQueryInfoKey(SafeRegistryHandle key, IntPtr cls,
        IntPtr clsLen, IntPtr reserved, IntPtr subKeys, IntPtr maxSubKey,
        IntPtr maxClass, IntPtr values, IntPtr maxValueName, IntPtr maxValueLen,
        IntPtr security, out long fileTime);
    public static DateTime RegistryTime(SafeRegistryHandle key) {
        long ft;
        int rc = RegQueryInfoKey(key, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
            IntPtr.Zero, IntPtr.Zero, out ft);
        return rc == 0 ? DateTime.FromFileTimeUtc(ft) : DateTime.MinValue;
    }
    [StructLayout(LayoutKind.Sequential)] private struct MemoryStatus {
        public uint Length, Load;
        public ulong TotalPhysical, AvailablePhysical, TotalPage, AvailablePage,
            TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
    [StructLayout(LayoutKind.Sequential)] private struct GpuUtilization { public uint Gpu, Memory; }
    [StructLayout(LayoutKind.Sequential)] private struct GpuMemory { public ulong Total, Free, Used; }
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    [DllImport("nvml.dll")] private static extern int nvmlInit_v2();
    [DllImport("nvml.dll")] private static extern int nvmlShutdown();
    [DllImport("nvml.dll")] private static extern int nvmlDeviceGetHandleByIndex_v2(uint index, out IntPtr device);
    [DllImport("nvml.dll", CharSet=CharSet.Ansi)] private static extern int nvmlDeviceGetName(IntPtr device, StringBuilder name, uint length);
    [DllImport("nvml.dll")] private static extern int nvmlDeviceGetUtilizationRates(IntPtr device, out GpuUtilization rates);
    [DllImport("nvml.dll")] private static extern int nvmlDeviceGetMemoryInfo(IntPtr device, out GpuMemory memory);
    [DllImport("nvml.dll")] private static extern int nvmlDeviceGetFanSpeed(IntPtr device, out uint speed);
    [DllImport("nvml.dll")] private static extern int nvmlDeviceGetPowerUsage(IntPtr device, out uint milliwatts);
    private static long previousIdle, previousTotal;
    private static bool sampled, initialized;
    private static IntPtr device;
    public static PanelSystemInfo ReadSystem() {
        PanelSystemInfo result = new PanelSystemInfo();
        MemoryStatus memory = new MemoryStatus();
        memory.Length = (uint)Marshal.SizeOf(typeof(MemoryStatus));
        if (GlobalMemoryStatusEx(ref memory)) {
            result.MemoryTotalGB = memory.TotalPhysical / 1073741824.0;
            result.MemoryUsedGB = (memory.TotalPhysical - memory.AvailablePhysical) / 1073741824.0;
            result.MemoryPercent = memory.Load;
        }
        long idle, kernel, user;
        if (GetSystemTimes(out idle, out kernel, out user)) {
            long total = kernel + user;
            if (sampled && total > previousTotal) {
                result.CpuPercent = Math.Max(0, Math.Min(100,
                    100.0 * (1.0 - (idle - previousIdle) / (double)(total - previousTotal))));
            }
            previousIdle = idle; previousTotal = total; sampled = true;
        }
        return result;
    }
    public static PanelGpuInfo ReadGpu() {
        try {
            if (!initialized) {
                if (nvmlInit_v2() != 0) return null;
                initialized = true;
                if (nvmlDeviceGetHandleByIndex_v2(0, out device) != 0) { Close(); return null; }
            }
            PanelGpuInfo result = new PanelGpuInfo();
            StringBuilder name = new StringBuilder(96);
            if (nvmlDeviceGetName(device, name, 96) != 0) return null;
            result.Name = name.ToString();
            GpuUtilization util; GpuMemory memory; uint value;
            if (nvmlDeviceGetUtilizationRates(device, out util) == 0) result.Utilization = util.Gpu;
            if (nvmlDeviceGetMemoryInfo(device, out memory) == 0) {
                result.MemoryUsedGB = memory.Used / 1073741824.0;
                result.MemoryTotalGB = memory.Total / 1073741824.0;
            }
            if (nvmlDeviceGetFanSpeed(device, out value) == 0) result.FanPercent = value;
            if (nvmlDeviceGetPowerUsage(device, out value) == 0) result.PowerWatts = value / 1000.0;
            return result;
        } catch (DllNotFoundException) { return null; }
          catch (EntryPointNotFoundException) { return null; }
    }
    public static void Close() {
        if (!initialized) return;
        try { nvmlShutdown(); } catch { }
        initialized = false; device = IntPtr.Zero;
    }
}
