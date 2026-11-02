# dsh-cu Windows action layer.
#
# One shot per call: this process starts, performs one action, prints a single
# JSON object and exits. Nothing stays resident between calls.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File win.ps1 -Request <base64-json>
#
# The request is base64-encoded JSON because PowerShell mangles quotes in
# command-line arguments on Windows.

param([Parameter(Mandatory = $true)][string]$Request)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$req = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Request)) | ConvertFrom-Json
$action = $req.action

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
# WinRT projection, needed for the built-in Windows OCR engine.
Add-Type -AssemblyName System.Runtime.WindowsRuntime

# Without this, Windows virtualizes coordinates for this process: Screen reports
# scaled sizes, window rects come back in a different space than the pixels
# GetCursorPos and SendInput use, and clicks land in the wrong place on scaled
# displays. Per-monitor awareness keeps every number in physical pixels.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class CuDpi {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static void Enable() {
    try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
    try { SetProcessDPIAware(); } catch { }
  }
}
"@
try { [CuDpi]::Enable() } catch { }

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class CuNative {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] p, int cb);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowExW(IntPtr parent, IntPtr child, string cls, string title);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int SendMessageW(IntPtr h, uint msg, IntPtr wp, StringBuilder lp);
  [DllImport("user32.dll")] public static extern int SendMessageW(IntPtr h, uint msg, IntPtr wp, IntPtr lp);

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  // HARDWAREINPUT only pads the union to its native size. Without it the struct
  // is 32 bytes on x64 instead of 40 and SendInput silently does nothing.
  [StructLayout(LayoutKind.Sequential)] public struct HARDWAREINPUT { public uint uMsg; public ushort wParamL, wParamH; }
  [StructLayout(LayoutKind.Explicit)] public struct InputUnion {
    [FieldOffset(0)] public MOUSEINPUT mi;
    [FieldOffset(0)] public KEYBDINPUT ki;
    [FieldOffset(0)] public HARDWAREINPUT hi;
  }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public InputUnion U; }

  const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
  const uint MDOWN = 0x0002, MUP = 0x0004, RDOWN = 0x0008, RUP = 0x0010;
  const uint MDOWN2 = 0x0020, MUP2 = 0x0040, WHEEL = 0x0800;
  const uint KEYUP = 0x0002, UNICODE = 0x0004;

  public static void Mouse(uint flags, int wheelDelta) {
    INPUT[] a = new INPUT[1];
    a[0].type = INPUT_MOUSE;
    a[0].U.mi.dwFlags = flags;
    a[0].U.mi.mouseData = (uint)wheelDelta;
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }

  public static void Button(string button, bool down) {
    uint f;
    if (button == "right") f = down ? RDOWN : RUP;
    else if (button == "middle") f = down ? MDOWN2 : MUP2;
    else f = down ? MDOWN : MUP;
    Mouse(f, 0);
  }

  public static void Key(ushort vk, bool up) {
    INPUT[] a = new INPUT[1];
    a[0].type = INPUT_KEYBOARD;
    a[0].U.ki.wVk = vk;
    a[0].U.ki.dwFlags = up ? KEYUP : 0;
    SendInput(1, a, Marshal.SizeOf(typeof(INPUT)));
  }

  // Unicode injection: types any character regardless of keyboard layout.
  public static int Text(string s) {
    int n = 0;
    foreach (char c in s) {
      INPUT[] d = new INPUT[1];
      d[0].type = INPUT_KEYBOARD;
      d[0].U.ki.wScan = (ushort)c;
      d[0].U.ki.dwFlags = UNICODE;
      n += (int)SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));

      INPUT[] u = new INPUT[1];
      u[0].type = INPUT_KEYBOARD;
      u[0].U.ki.wScan = (ushort)c;
      u[0].U.ki.dwFlags = UNICODE | KEYUP;
      n += (int)SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
    }
    return n;
  }

  // Win32 Edit controls answer WM_GETTEXT, which is far more reliable than
  // screen-scraping a text field. Returns null when the window has no Edit.
  public static string EditText(IntPtr hwnd) {
    IntPtr e = FindWindowExW(hwnd, IntPtr.Zero, "Edit", null);
    if (e == IntPtr.Zero) return null;
    int len = SendMessageW(e, 0x000E, IntPtr.Zero, IntPtr.Zero);
    StringBuilder sb = new StringBuilder(len + 2);
    SendMessageW(e, 0x000D, (IntPtr)(len + 1), sb);
    return sb.ToString();
  }
}
"@

# ------------------------------------------------------------------ monitors
function Get-Monitors {
  $i = 0
  @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
      $i++
      [pscustomobject]@{
        index   = $i
        device  = $_.DeviceName
        primary = $_.Primary
        x = $_.Bounds.X; y = $_.Bounds.Y
        width = $_.Bounds.Width; height = $_.Bounds.Height
      }
    })
}

function Get-MonitorAt([int]$x, [int]$y) {
  $i = 0
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $i++
    $b = $s.Bounds
    if ($x -ge $b.X -and $x -lt ($b.X + $b.Width) -and $y -ge $b.Y -and $y -lt ($b.Y + $b.Height)) { return $i }
  }
  return 0
}

# A window dragged partly off-screen has its top-left corner outside every
# monitor, so point tests return 0. Pick the monitor with the largest overlap.
function Get-MonitorForRect([int]$x, [int]$y, [int]$w, [int]$h) {
  $best = 0
  $bestArea = 0
  $i = 0
  foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
    $i++
    $b = $s.Bounds
    $ox = [Math]::Max(0, [Math]::Min($x + $w, $b.X + $b.Width) - [Math]::Max($x, $b.X))
    $oy = [Math]::Max(0, [Math]::Min($y + $h, $b.Y + $b.Height) - [Math]::Max($y, $b.Y))
    $area = $ox * $oy
    if ($area -gt $bestArea) { $bestArea = $area; $best = $i }
  }
  return $best
}

function Get-MonitorByIndex([int]$index) {
  Get-Monitors | Where-Object { $_.index -eq $index } | Select-Object -First 1
}

# ------------------------------------------------------------------- windows
function Get-Windows {
  $out = New-Object System.Collections.ArrayList
  $procs = @{}
  Get-Process | ForEach-Object { $procs[$_.Id] = $_.ProcessName }

  $kids = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children,
    [System.Windows.Automation.Condition]::TrueCondition)

  foreach ($el in $kids) {
    try {
      $h = [IntPtr]$el.Current.NativeWindowHandle
      if ($h -eq [IntPtr]::Zero) { continue }
      if (-not [CuNative]::IsWindowVisible($h)) { continue }
      $title = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($title)) { continue }

      $r = New-Object CuNative+RECT
      if (-not [CuNative]::GetWindowRect($h, [ref]$r)) { continue }
      $w = $r.R - $r.L
      $hh = $r.B - $r.T
      if ($w -le 0 -or $hh -le 0) { continue }

      $procId = [uint32]0
      [void][CuNative]::GetWindowThreadProcessId($h, [ref]$procId)

      [void]$out.Add([pscustomobject]@{
          hwnd      = $h.ToInt64()
          title     = $title
          process   = $procs[[int]$procId]
          pid       = [int]$procId
          x = $r.L; y = $r.T; width = $w; height = $hh
          monitor   = (Get-MonitorForRect $r.L $r.T $w $hh)
          minimized = [CuNative]::IsIconic($h)
        })
    } catch { }
  }
  return $out
}

function Find-Window([string]$match) {
  # Prefer a real application window over helper surfaces such as overlays.
  # Largest-area alone picks "Discord Overlay" over "Friends - Discord".
  $all = @(Get-Windows | Where-Object { $_.title -like "*$match*" })
  if ($all.Count -eq 0) { return $null }
  if ($all.Count -eq 1) { return $all[0] }

  $helpers = 'Overlay|Helper|Hidden|IME|MSCTFIME|Default IME|NotifyIcon|Tooltip'
  $real = @($all | Where-Object { $_.title -notmatch $helpers })
  $pool = if ($real.Count -gt 0) { $real } else { $all }
  $pool | Sort-Object @{ Expression = { $_.width * $_.height }; Descending = $true } |
    Select-Object -First 1
}

# SetForegroundWindow only succeeds when the caller already owns the foreground,
# which a short-lived helper never does. Tapping Alt first clears that lock
# (Windows counts it as user activity). Returns whether the target really took.
function Set-Foreground([IntPtr]$hwnd) {
  if ([CuNative]::IsIconic($hwnd)) { [void][CuNative]::ShowWindow($hwnd, 9) }
  if ([CuNative]::GetForegroundWindow() -eq $hwnd) { return $true }

  [CuNative]::Key(0x12, $false)
  Start-Sleep -Milliseconds 50
  [CuNative]::Key(0x12, $true)
  Start-Sleep -Milliseconds 80

  [void][CuNative]::BringWindowToTop($hwnd)
  [void][CuNative]::SetForegroundWindow($hwnd)
  Start-Sleep -Milliseconds 350

  if ([CuNative]::GetForegroundWindow() -eq $hwnd) { return $true }

  try {
    $procId = [uint32]0
    [void][CuNative]::GetWindowThreadProcessId($hwnd, [ref]$procId)
    $shell = New-Object -ComObject WScript.Shell
    [void]$shell.AppActivate([int]$procId)
    Start-Sleep -Milliseconds 400
  } catch { }

  return ([CuNative]::GetForegroundWindow() -eq $hwnd)
}

# Clicking inside a control is what actually gives it keyboard focus. Bringing
# a window forward alone often leaves the caret somewhere else.
function Click-Into([IntPtr]$hwnd) {
  $r = New-Object CuNative+RECT
  if (-not [CuNative]::GetWindowRect($hwnd, [ref]$r)) { return }
  $x = [int](($r.L + $r.R) / 2)
  $y = [int]($r.T + ($r.B - $r.T) * 0.45)
  [void][CuNative]::SetCursorPos($x, $y)
  Start-Sleep -Milliseconds 80
  [CuNative]::Button('left', $true)
  Start-Sleep -Milliseconds 40
  [CuNative]::Button('left', $false)
  Start-Sleep -Milliseconds 300
}

# -------------------------------------------------------------------- capture
function Save-WindowPng($win, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap $win.width, $win.height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  # PrintWindow renders the window itself, so an occluded or background window
  # still captures correctly. CopyFromScreen would grab whatever is on top.
  $ok = [CuNative]::PrintWindow([IntPtr]$win.hwnd, $hdc, 2)
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  if (-not $ok) { $bmp.Dispose(); throw "PrintWindow failed for '$($win.title)'" }
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

function Save-MonitorPng($mon, [string]$path) {
  $bmp = New-Object System.Drawing.Bitmap $mon.width, $mon.height
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($mon.x, $mon.y, 0, 0, (New-Object System.Drawing.Size($mon.width, $mon.height)))
  $g.Dispose()
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

# ------------------------------------------------------------------------ OCR
$script:OcrAsTask = $null
function Invoke-Ocr([string]$imagePath) {
  if (-not $script:OcrAsTask) {
    $script:OcrAsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
      })[0]
  }
  $asTask = $script:OcrAsTask

  function Await($op, $type) {
    $t = $asTask.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(20000) | Out-Null
    $t.Result
  }

  [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
  [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime] | Out-Null
  [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null

  $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($imagePath)) ([Windows.Storage.StorageFile])
  $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
  $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
  $bitmap = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])

  $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
  if (-not $engine) { throw 'no OCR engine installed for the current user languages' }
  $res = Await ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])

  $words = New-Object System.Collections.ArrayList
  foreach ($line in $res.Lines) {
    foreach ($w in $line.Words) {
      [void]$words.Add([pscustomobject]@{
          text = $w.Text
          x = [int]$w.BoundingRect.X; y = [int]$w.BoundingRect.Y
          w = [int]$w.BoundingRect.Width; h = [int]$w.BoundingRect.Height
        })
    }
  }
  [pscustomobject]@{
    text  = $res.Text
    lines = @($res.Lines | ForEach-Object { $_.Text })
    words = @($words)
  }
}

# ------------------------------------------------------------------ UIA lookup
function Get-UiaElements($win, [int]$limit = 250) {
  $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.hwnd)
  if (-not $root) { return @() }

  $all = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.Condition]::TrueCondition)
  $out = New-Object System.Collections.ArrayList
  foreach ($el in $all) {
    if ($out.Count -ge $limit) { break }
    try {
      $name = $el.Current.Name
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      $r = $el.Current.BoundingRectangle
      if ($r.Width -le 0 -or $r.Height -le 0) { continue }
      [void]$out.Add([pscustomobject]@{
          name        = $name
          controlType = ($el.Current.ControlType.ProgrammaticName -replace 'ControlType\.', '')
          x = [int]$r.X; y = [int]$r.Y; w = [int]$r.Width; h = [int]$r.Height
          cx = [int]($r.X + $r.Width / 2); cy = [int]($r.Y + $r.Height / 2)
        })
    } catch { }
  }
  return $out
}

# ---------------------------------------------------------------- key mapping
function Get-KeyMap {
  @{
    'win' = 0x5B; 'ctrl' = 0x11; 'control' = 0x11; 'alt' = 0x12; 'shift' = 0x10
    'enter' = 0x0D; 'return' = 0x0D; 'esc' = 0x1B; 'escape' = 0x1B; 'tab' = 0x09
    'space' = 0x20; 'backspace' = 0x08; 'delete' = 0x2E; 'up' = 0x26; 'down' = 0x28
    'left' = 0x25; 'right' = 0x27; 'home' = 0x24; 'end' = 0x23
    'pageup' = 0x21; 'pagedown' = 0x22; 'insert' = 0x2D
    'f1' = 0x70; 'f2' = 0x71; 'f3' = 0x72; 'f4' = 0x73; 'f5' = 0x74
    'f6' = 0x75; 'f7' = 0x76; 'f8' = 0x77; 'f9' = 0x78; 'f10' = 0x79
    'f11' = 0x7A; 'f12' = 0x7B
  }
}

function Respond($obj) {
  $obj | ConvertTo-Json -Depth 8 -Compress
  exit 0
}

$tmpDir = Join-Path $env:TEMP 'dsh-cu'
if (-not (Test-Path $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir | Out-Null }

try {
  switch ($action) {

    'monitors' {
      Respond @{ ok = $true; monitors = @(Get-Monitors) }
    }

    'windows' {
      $w = @(Get-Windows)
      if ($req.monitor) { $w = @($w | Where-Object { $_.monitor -eq [int]$req.monitor }) }
      Respond @{ ok = $true; windows = $w }
    }

    'screenshot' {
      $path = Join-Path $tmpDir ("shot-" + [guid]::NewGuid().ToString('N') + '.png')
      if ($req.window) {
        $win = Find-Window $req.window
        if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
        Save-WindowPng $win $path
        Respond @{ ok = $true; path = $path; target = 'window'; title = $win.title
          bounds = @{ x = $win.x; y = $win.y; width = $win.width; height = $win.height }
        }
      }
      $mon = Get-MonitorByIndex $(if ($req.monitor) { [int]$req.monitor } else { 1 })
      if (-not $mon) { Respond @{ ok = $false; error = "no monitor $($req.monitor)" } }
      Save-MonitorPng $mon $path
      Respond @{ ok = $true; path = $path; target = 'monitor'; monitor = $mon.index
        bounds = @{ x = $mon.x; y = $mon.y; width = $mon.width; height = $mon.height }
      }
    }

    'ocr' {
      $path = Join-Path $tmpDir ("ocr-" + [guid]::NewGuid().ToString('N') + '.png')
      if ($req.window) {
        $win = Find-Window $req.window
        if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
        Save-WindowPng $win $path
        $origin = @{ x = $win.x; y = $win.y }
        $target = $win.title
      } else {
        $mon = Get-MonitorByIndex $(if ($req.monitor) { [int]$req.monitor } else { 1 })
        if (-not $mon) { Respond @{ ok = $false; error = "no monitor $($req.monitor)" } }
        Save-MonitorPng $mon $path
        $origin = @{ x = $mon.x; y = $mon.y }
        $target = "monitor $($mon.index)"
      }
      $r = Invoke-Ocr $path
      # Report absolute screen coordinates so the caller can click them directly.
      foreach ($w in $r.words) { $w.x = $w.x + $origin.x; $w.y = $w.y + $origin.y }
      Respond @{ ok = $true; target = $target; text = $r.text; lines = $r.lines
        words = @($r.words); origin = $origin
      }
    }

    'uia' {
      $win = Find-Window $req.window
      if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
      $limit = if ($req.limit) { [int]$req.limit } else { 250 }
      Respond @{ ok = $true; title = $win.title; elements = @(Get-UiaElements $win $limit) }
    }

    'read' {
      # Read a Win32 Edit control directly. Null means the window is not one.
      $win = Find-Window $req.window
      if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
      $text = [CuNative]::EditText([IntPtr]$win.hwnd)
      Respond @{ ok = $true; title = $win.title; text = $text
        supported = ($null -ne $text) }
    }

    'click' {
      $x = [int]$req.x
      $y = [int]$req.y

      if ($req.monitor) {
        $mon = Get-MonitorAt $x $y
        if ($mon -ne [int]$req.monitor) {
          Respond @{ ok = $false; error = "point $x,$y is on monitor $mon, not the selected monitor $($req.monitor)" }
        }
      }

      # A named control can be activated without touching the mouse at all.
      if ($req.uia -and $req.window) {
        $win = Find-Window $req.window
        if ($win) {
          $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$win.hwnd)
          $cond = New-Object System.Windows.Automation.PropertyCondition(
            [System.Windows.Automation.AutomationElement]::NameProperty, $req.uia)
          $found = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
          if ($found) {
            try {
              $p = $found.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
              $p.Invoke()
              Respond @{ ok = $true; method = 'uia-invoke'; element = $req.uia; background = $true }
            } catch { }
          }
        }
      }

      if ($req.mode -eq 'background') {
        Respond @{ ok = $false; error = 'background mode cannot click a raw coordinate; pass a control name (uia) or use foreground mode' }
      }

      if ($req.window) {
        $win = Find-Window $req.window
        if ($win -and -not (Set-Foreground ([IntPtr]$win.hwnd))) {
          Respond @{ ok = $false; error = "could not bring '$($win.title)' to the foreground; nothing was clicked" }
        }
      }

      [void][CuNative]::SetCursorPos($x, $y)
      Start-Sleep -Milliseconds 80

      $button = if ($req.button) { $req.button } else { 'left' }
      $times = if ($req.double) { 2 } else { 1 }
      for ($i = 0; $i -lt $times; $i++) {
        [CuNative]::Button($button, $true)
        Start-Sleep -Milliseconds 40
        [CuNative]::Button($button, $false)
        Start-Sleep -Milliseconds 70
      }
      Respond @{ ok = $true; method = 'mouse'; x = $x; y = $y; button = $button; double = [bool]$req.double }
    }

    'type' {
      if ($req.window) {
        $win = Find-Window $req.window
        if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
        if (-not (Set-Foreground ([IntPtr]$win.hwnd))) {
          # Typing blind would land the text in whatever window is in front,
          # which could be someone else's chat box. Refuse instead.
          Respond @{ ok = $false; error = "could not bring '$($win.title)' to the foreground; nothing was typed" }
        }
        if ($req.clickInto) { Click-Into ([IntPtr]$win.hwnd) }
        Start-Sleep -Milliseconds 250
      }
      $sent = [CuNative]::Text([string]$req.text)
      Respond @{ ok = $true; method = 'sendinput-unicode'; length = ([string]$req.text).Length; events = $sent }
    }

    'key' {
      $map = Get-KeyMap
      $keys = @($req.keys)
      if ($keys.Count -eq 0) { Respond @{ ok = $false; error = 'keys is empty' } }

      $vks = @()
      foreach ($k in $keys) {
        $lk = ([string]$k).ToLowerInvariant()
        if ($map.ContainsKey($lk)) { $vks += $map[$lk] }
        elseif ($lk.Length -eq 1) { $vks += [int][char]$lk.ToUpperInvariant() }
        else { Respond @{ ok = $false; error = "unknown key '$k'" } }
      }

      if ($req.window) {
        $win = Find-Window $req.window
        if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
        if (-not (Set-Foreground ([IntPtr]$win.hwnd))) {
          Respond @{ ok = $false; error = "could not bring '$($win.title)' to the foreground; nothing was sent" }
        }
        Start-Sleep -Milliseconds 150
      }

      foreach ($vk in $vks) { [CuNative]::Key([uint16]$vk, $false); Start-Sleep -Milliseconds 40 }
      for ($i = $vks.Count - 1; $i -ge 0; $i--) { [CuNative]::Key([uint16]$vks[$i], $true); Start-Sleep -Milliseconds 40 }

      Respond @{ ok = $true; method = 'sendinput-keys'; keys = $keys }
    }

    'focus' {
      $win = Find-Window $req.window
      if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
      $took = Set-Foreground ([IntPtr]$win.hwnd)
      Respond @{ ok = $took; title = $win.title; hwnd = $win.hwnd
        error = $(if ($took) { $null } else { 'could not take the foreground from another window' })
      }
    }

    'move' {
      # Windows get dragged partly off-screen, which puts their controls out of
      # reach of both clicks and captures. This brings one back into view.
      $win = Find-Window $req.window
      if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
      if ($win.minimized) { [void][CuNative]::ShowWindow([IntPtr]$win.hwnd, 9) }
      $nx = [int]$req.x
      $ny = [int]$req.y
      $nw = if ($req.width) { [int]$req.width } else { $win.width }
      $nh = if ($req.height) { [int]$req.height } else { $win.height }
      [void][CuNative]::SetWindowPos([IntPtr]$win.hwnd, [IntPtr]::Zero, $nx, $ny, $nw, $nh, 0x0014)
      Start-Sleep -Milliseconds 400
      $after = Find-Window $req.window
      Respond @{ ok = $true; title = $after.title; x = $after.x; y = $after.y
        width = $after.width; height = $after.height; monitor = $after.monitor }
    }

    'fit' {
      # Fit a window inside one monitor's work area, clear of the taskbar.
      $win = Find-Window $req.window
      if (-not $win) { Respond @{ ok = $false; error = "no visible window matching '$($req.window)'" } }
      if ($win.minimized) { [void][CuNative]::ShowWindow([IntPtr]$win.hwnd, 9) }
      $mon = Get-MonitorByIndex $(if ($req.monitor) { [int]$req.monitor } else { 1 })
      if (-not $mon) { Respond @{ ok = $false; error = "no monitor $($req.monitor)" } }

      $screen = [System.Windows.Forms.Screen]::AllScreens |
        Where-Object { $_.Bounds.X -eq $mon.x -and $_.Bounds.Y -eq $mon.y } |
        Select-Object -First 1
      $area = if ($screen) { $screen.WorkingArea } else {
        New-Object System.Drawing.Rectangle $mon.x, $mon.y, $mon.width, $mon.height
      }
      $pad = 8
      # SW_RESTORE first: a maximized window ignores SetWindowPos position.
      # SWP_SHOWWINDOW (0x0040) makes sure it is actually visible after the move.
      [void][CuNative]::ShowWindow([IntPtr]$win.hwnd, 9)
      Start-Sleep -Milliseconds 250
      [void][CuNative]::SetWindowPos([IntPtr]$win.hwnd, [IntPtr]::Zero,
        $area.X + $pad, $area.Y + $pad, $area.Width - (2 * $pad), $area.Height - (2 * $pad), 0x0044)
      Start-Sleep -Milliseconds 500
      $after = Find-Window $req.window
      Respond @{ ok = $true; title = $after.title; monitor = $after.monitor
        x = $after.x; y = $after.y; width = $after.width; height = $after.height }
    }

    'startmenu' {
      # The Start menu path: Win key, type a query, optionally press Enter.
      if ($req.window) {
        $win = Find-Window $req.window
        if ($win) { [void](Set-Foreground ([IntPtr]$win.hwnd)) }
      }
      [CuNative]::Key(0x5B, $false); Start-Sleep -Milliseconds 80; [CuNative]::Key(0x5B, $true)
      Start-Sleep -Milliseconds 900

      if ($req.query) {
        [CuNative]::Text([string]$req.query)
        Start-Sleep -Milliseconds 1400
        if ($req.open -ne $false) {
          [CuNative]::Key(0x0D, $false); Start-Sleep -Milliseconds 60; [CuNative]::Key(0x0D, $true)
          Start-Sleep -Milliseconds 1200
        }
      }
      Respond @{ ok = $true; action = 'startmenu'; query = $req.query; opened = ($req.open -ne $false) }
    }

    'launch' {
      Start-Process -FilePath $req.target
      Respond @{ ok = $true; launched = $req.target }
    }

    'open' {
      # ShellExecute handles apps, documents, folders and URLs. The Start menu
      # only finds indexed items, so an unindexed file still opens here.
      $t = [string]$req.path
      if (-not $t) { Respond @{ ok = $false; error = 'path is empty' } }
      $isUrl = $t -match '^[a-z][a-z0-9+.-]*://'
      if (-not $isUrl -and -not (Test-Path -LiteralPath $t)) {
        Respond @{ ok = $false; error = "no such file or folder: $t" }
      }
      if ($isUrl) { Start-Process $t }
      else { Start-Process -FilePath (Resolve-Path -LiteralPath $t).Path }
      Respond @{ ok = $true; opened = $t; kind = $(if ($isUrl) { 'url' } else { 'path' }) }
    }

    'scroll' {
      $x = if ($req.x) { [int]$req.x } else { [System.Windows.Forms.Cursor]::Position.X }
      $y = if ($req.y) { [int]$req.y } else { [System.Windows.Forms.Cursor]::Position.Y }
      [void][CuNative]::SetCursorPos($x, $y)
      Start-Sleep -Milliseconds 60
      $delta = if ($req.delta) { [int]$req.delta } else { -480 }
      [CuNative]::Mouse(0x0800, $delta)
      Respond @{ ok = $true; action = 'scroll'; delta = $delta; x = $x; y = $y }
    }

    default {
      Respond @{ ok = $false; error = "unknown action '$action'" }
    }
  }
} catch {
  Respond @{ ok = $false; error = $_.Exception.Message }
}
