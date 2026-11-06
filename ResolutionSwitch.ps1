# Windows display resolution switcher v3.
# Changes the Windows PRIMARY desktop display, not any game config.
# Compatible with Windows PowerShell 5.1 (Windows 10/11).
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Apply', 'Restore', 'List', 'Diagnose')]
    [string] $Action,
    [ValidateRange(320, 16384)] [int] $Width = 1920,
    [ValidateRange(200, 16384)] [int] $Height = 1440
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$backupDir = Join-Path $env:LOCALAPPDATA 'ScreenResolutionSwitcher'
$backupPath = Join-Path $backupDir 'original-resolution.json'

# Keep ALL marshaling and ref parameters inside compiled C#: this avoids
# PowerShell's type-marshaling overload/ref quirks. Address the primary device
# explicitly instead of relying solely on a null device name.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DisplayDevMode
{
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion;
    public ushort dmDriverVersion;
    public ushort dmSize;
    public ushort dmDriverExtra;
    public uint dmFields;
    // The display branch of the DEVMODE union; 16 bytes.
    public int dmPositionX;
    public int dmPositionY;
    public uint dmDisplayOrientation;
    public uint dmDisplayFixedOutput;
    public short dmColor;
    public short dmDuplex;
    public short dmYResolution;
    public short dmTTOption;
    public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel;
    public uint dmPelsWidth;
    public uint dmPelsHeight;
    public uint dmDisplayFlags;
    public uint dmDisplayFrequency;
    public uint dmICMMethod;
    public uint dmICMIntent;
    public uint dmMediaType;
    public uint dmDitherType;
    public uint dmReserved1;
    public uint dmReserved2;
    public uint dmPanningWidth;
    public uint dmPanningHeight;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct DisplayDeviceInfo
{
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public uint StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
}

public sealed class ResMode
{
    public DisplayDevMode NativeMode;
    public string DeviceName;
    public int Width { get { return (int)NativeMode.dmPelsWidth; } }
    public int Height { get { return (int)NativeMode.dmPelsHeight; } }
    public int Hz { get { return (int)NativeMode.dmDisplayFrequency; } }
    public int Bits { get { return (int)NativeMode.dmBitsPerPel; } }
    public int Orientation { get { return (int)NativeMode.dmDisplayOrientation; } }
}

public static class DisplayNative
{
    [DllImport("user32.dll", EntryPoint = "EnumDisplayDevicesW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumDisplayDevices(string device, uint index, ref DisplayDeviceInfo output, uint flags);

    [DllImport("user32.dll", EntryPoint = "EnumDisplaySettingsExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool EnumDisplaySettingsEx(string device, int modeIndex, ref DisplayDevMode mode, uint flags);

    [DllImport("user32.dll", EntryPoint = "ChangeDisplaySettingsExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int ChangeDisplaySettingsEx(string device, ref DisplayDevMode mode, IntPtr hwnd, uint flags, IntPtr lparam);

    public const uint PRIMARY_DEVICE = 0x00000004;
    public const uint ATTACHED_TO_DESKTOP = 0x00000001;
    public const uint CDS_TEST = 0x00000002;
    public const uint CDS_UPDATEREGISTRY = 0x00000001;
    public static string LastDiagnostics = "";

    private static DisplayDevMode NewMode()
    {
        DisplayDevMode d = new DisplayDevMode();
        d.dmDeviceName = "";
        d.dmFormName = "";
        d.dmSize = checked((ushort)Marshal.SizeOf(typeof(DisplayDevMode)));
        return d;
    }

    public static int ModeStructureSize { get { return Marshal.SizeOf(typeof(DisplayDevMode)); } }
    public static int DeviceStructureSize { get { return Marshal.SizeOf(typeof(DisplayDeviceInfo)); } }

    public static List<DisplayDeviceInfo> GetDevices()
    {
        List<DisplayDeviceInfo> list = new List<DisplayDeviceInfo>();
        for (uint i = 0; i < 64; i++)
        {
            DisplayDeviceInfo d = new DisplayDeviceInfo();
            d.cb = Marshal.SizeOf(typeof(DisplayDeviceInfo));
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            list.Add(d);
        }
        return list;
    }

    private static ResMode ReadCurrent(string device)
    {
        DisplayDevMode mode = NewMode();
        bool ok = EnumDisplaySettingsEx(device, -1, ref mode, 0);
        if (!ok)
        {
            // Some drivers expect enumerated mode zero to initialize the cache.
            DisplayDevMode probe = NewMode();
            EnumDisplaySettingsEx(device, 0, ref probe, 0);
            mode = NewMode();
            ok = EnumDisplaySettingsEx(device, -1, ref mode, 0);
        }
        if (!ok) return null;
        ResMode result = new ResMode();
        result.NativeMode = mode;
        result.DeviceName = device;
        return result;
    }

    public static ResMode GetCurrentPrimary()
    {
        StringBuilder diagnostics = new StringBuilder();
        List<DisplayDeviceInfo> devices = GetDevices();
        diagnostics.AppendLine("DEVMODE size=" + ModeStructureSize + "; DISPLAY_DEVICE size=" + DeviceStructureSize);
        diagnostics.AppendLine("Detected display adapters: " + devices.Count);
        List<string> ordered = new List<string>();
        foreach (DisplayDeviceInfo d in devices)
        {
            diagnostics.AppendLine("  " + d.DeviceName + " | primary=" + ((d.StateFlags & PRIMARY_DEVICE) != 0) + " | attached=" + ((d.StateFlags & ATTACHED_TO_DESKTOP) != 0) + " | " + d.DeviceString);
            if ((d.StateFlags & PRIMARY_DEVICE) != 0 && (d.StateFlags & ATTACHED_TO_DESKTOP) != 0 && !ordered.Contains(d.DeviceName))
                ordered.Add(d.DeviceName);
        }
        // Only use another attached adapter when Windows did not report any primary.
        // Never silently change a secondary monitor because a known primary failed.
        if (ordered.Count == 0)
        {
            foreach (DisplayDeviceInfo d in devices)
                if ((d.StateFlags & ATTACHED_TO_DESKTOP) != 0 && !ordered.Contains(d.DeviceName)) ordered.Add(d.DeviceName);
        }
        // Try default display if device enumeration was unavailable/inaccurate.
        ordered.Add(null);
        foreach (string device in ordered)
        {
            ResMode mode = ReadCurrent(device);
            string label = (device == null) ? "(default)" : device;
            if (mode != null)
            {
                diagnostics.AppendLine("EnumDisplaySettingsEx " + label + ": OK (" + mode.Width + "x" + mode.Height + ", " + mode.Hz + " Hz)");
                LastDiagnostics = diagnostics.ToString();
                return mode;
            }
            diagnostics.AppendLine("EnumDisplaySettingsEx " + label + ": FAILED (Win32 last error=" + Marshal.GetLastWin32Error() + ")");
        }
        LastDiagnostics = diagnostics.ToString();
        return null;
    }

    public static List<ResMode> ListModes(string device)
    {
        List<ResMode> list = new List<ResMode>();
        for (int i = 0; i < 8192; i++)
        {
            DisplayDevMode mode = NewMode();
            if (!EnumDisplaySettingsEx(device, i, ref mode, 0)) break;
            ResMode r = new ResMode();
            r.NativeMode = mode;
            r.DeviceName = device;
            list.Add(r);
        }
        return list;
    }

    public static ResMode FindMode(string device, int width, int height, int preferHz, int preferBits, int preferOrientation)
    {
        ResMode best = null;
        long bestScore = long.MaxValue;
        foreach (ResMode r in ListModes(device))
        {
            if (r.Width != width || r.Height != height) continue;
            if (r.Orientation != preferOrientation) continue;
            // Preserve color depth and refresh rate when supported.
            long score = (r.Bits == preferBits ? 0L : 1000000L) + 1000L * Math.Abs(r.Hz - preferHz);
            if (best == null || score < bestScore)
            {
                best = r;
                bestScore = score;
            }
        }
        return best;
    }

    public static int Change(string device, ResMode desired, uint flags)
    {
        DisplayDevMode mode = desired.NativeMode;
        return ChangeDisplaySettingsEx(device, ref mode, IntPtr.Zero, flags, IntPtr.Zero);
    }
}
'@ -ErrorAction Stop

function Format-Mode($mode) {
    return ('{0}x{1} @ {2} Hz, {3}-bit' -f $mode.Width, $mode.Height, $mode.Hz, $mode.Bits)
}

function Get-PrimaryMode {
    $mode = [DisplayNative]::GetCurrentPrimary()
    if ($null -eq $mode) {
        Write-Host '显示器查询诊断信息：' -ForegroundColor Yellow
        Write-Host ([DisplayNative]::LastDiagnostics)
        throw '无法通过 Windows 显示 API 读取主显示器。请运行 04-Diagnose.bat，并将窗口内容发给我。'
    }
    return $mode
}

function Find-BackupMode($backup, $device) {
    $target = [DisplayNative]::FindMode(
        $device, [int]$backup.Width, [int]$backup.Height, [int]$backup.RefreshHz,
        [int]$backup.ColorBits, [int]$backup.Orientation)
    if ($null -eq $target) {
        throw ('找不到备份的显示模式：{0}x{1}，{2} Hz。备份仍在 {3}' -f $backup.Width, $backup.Height, $backup.RefreshHz, $backupPath)
    }
    return $target
}

function Apply-Mode($mode, $device) {
    $test = [DisplayNative]::Change($device, $mode, [DisplayNative]::CDS_TEST)
    if ($test -ne 0) {
        throw ('显示器驱动不允许这个模式，测试返回码：{0}（0 成功，-2 不支持，-5 参数错误）。未切换。' -f $test)
    }
    $change = [DisplayNative]::Change($device, $mode, [DisplayNative]::CDS_UPDATEREGISTRY)
    if ($change -ne 0) {
        throw ('切换 Windows 分辨率失败，返回码：{0}（0 成功，1 需要重启，-2 不支持）。' -f $change)
    }
}

function Mode-Snapshot($mode) {
    return [pscustomobject]@{
        Width       = [int]$mode.Width
        Height      = [int]$mode.Height
        RefreshHz   = [int]$mode.Hz
        ColorBits   = [int]$mode.Bits
        Orientation = [int]$mode.Orientation
    }
}

try {
    if ($Action -eq 'Diagnose') {
        $mode = [DisplayNative]::GetCurrentPrimary()
        Write-Host ('DEVMODE 结构体大小：{0} bytes（正常应为 220）' -f [DisplayNative]::ModeStructureSize)
        Write-Host ([DisplayNative]::LastDiagnostics)
        if ($null -eq $mode) {
            try {
                Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                $screen = [System.Windows.Forms.Screen]::PrimaryScreen
                if ($null -ne $screen) {
                    Write-Host ('Windows Forms 检测主屏：{0}, {1}x{2}' -f $screen.DeviceName, $screen.Bounds.Width, $screen.Bounds.Height)
                } else { Write-Host 'Windows Forms 也未找到主屏。' }
            } catch {
                Write-Host ('Windows Forms 查询失败：' + $_.Exception.Message)
            }
            exit 2
        }
        Write-Host ('已成功读取当前显示模式：' + (Format-Mode $mode)) -ForegroundColor Green
        $modeCount = ([DisplayNative]::ListModes($mode.DeviceName)).Count
        Write-Host ('驱动报告的显示模式数量：{0}' -f $modeCount)
        exit 0
    }

    $current = Get-PrimaryMode
    Write-Host ('当前 Windows 主屏幕：' + (Format-Mode $current)) -ForegroundColor Cyan
    Write-Host ('显示器设备：' + $(if ($current.DeviceName) { $current.DeviceName } else { '(默认)' }))

    if ($Action -eq 'List') {
        $modes = [DisplayNative]::ListModes($current.DeviceName)
        if ($modes.Count -eq 0) { throw '驱动没有返回支持的显示模式。运行 04-Diagnose.bat 获取诊断信息。' }
        $modes | ForEach-Object { '{0}x{1} @ {2}Hz' -f $_.Width, $_.Height, $_.Hz } |
            Sort-Object -Unique | Write-Output
        exit 0
    }

    if ($Action -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $backupPath)) {
            throw ('没有备份文件：' + $backupPath + '。如果你没成功切换过，可直接在 Windows 显示设置中调整。')
        }
        $backup = Get-Content -LiteralPath $backupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $restoreMode = Find-BackupMode $backup $current.DeviceName
        Apply-Mode $restoreMode $current.DeviceName
        Write-Host ('已恢复 Windows 分辨率：' + (Format-Mode $restoreMode)) -ForegroundColor Green
        Remove-Item -LiteralPath $backupPath -Force
        exit 0
    }

    if ($current.Width -eq $Width -and $current.Height -eq $Height) {
        Write-Host ('当前已经是 {0}x{1}，无需操作。' -f $Width, $Height) -ForegroundColor Green
        exit 0
    }

    $desired = [DisplayNative]::FindMode($current.DeviceName, $Width, $Height,
        $current.Hz, $current.Bits, $current.Orientation)
    if ($null -eq $desired) {
        throw ('显卡驱动未列出 {0}x{1} 这个显示模式。运行 03-List-Supported-Modes.bat 查看可用分辨率。' -f $Width, $Height)
    }
    # Validate before creating the backup.
    $test = [DisplayNative]::Change($current.DeviceName, $desired, [DisplayNative]::CDS_TEST)
    if ($test -ne 0) { throw ('目标模式测试失败，返回码：' + $test + '；未修改分辨率。') }

    $createdNewBackup = $false
    if (-not (Test-Path -LiteralPath $backupPath)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Mode-Snapshot $current | ConvertTo-Json | Set-Content -LiteralPath $backupPath -Encoding UTF8
        $createdNewBackup = $true
        Write-Host ('原分辨率已备份至：' + $backupPath)
    } else {
        Write-Host ('检测到之前备份，保留最初设置：' + $backupPath) -ForegroundColor Yellow
    }

    try {
        Apply-Mode $desired $current.DeviceName
    } catch {
        if ($createdNewBackup) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue }
        throw
    }

    Write-Host ('已切换 Windows 桌面：' + (Format-Mode $desired)) -ForegroundColor Green
    Write-Host '请在 20 秒内按 Y 确认新模式；按 N 或超时将恢复。' -ForegroundColor Yellow
    & "$env:SystemRoot\System32\choice.exe" /C YN /T 20 /D N /M '画面正常吗? Y=保留 N=恢复'
    if ($LASTEXITCODE -eq 1) {
        Write-Host '已保留。以后要恢复，运行 02-Restore-Original.bat。' -ForegroundColor Green
        exit 0
    }

    Write-Host '正在自动恢复本次切换前的显示设置...' -ForegroundColor Yellow
    try {
        $previous = Mode-Snapshot $current
        $rollback = Find-BackupMode $previous $current.DeviceName
        Apply-Mode $rollback $current.DeviceName
        if ($createdNewBackup) { Remove-Item -LiteralPath $backupPath -Force }
        Write-Host ('已恢复：' + (Format-Mode $rollback)) -ForegroundColor Green
    } catch {
        Write-Host ('自动恢复失败：' + $_.Exception.Message) -ForegroundColor Red
        Write-Host ('备份位置：' + $backupPath)
        throw
    }
} catch {
    Write-Host ('错误：' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
