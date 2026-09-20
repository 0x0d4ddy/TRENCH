# Snapshot of the hung game for the dump reader: thread stacks and the module list, nothing else.
# Task Manager's "Create dump file" writes full process memory instead - gigabytes, minutes of
# waiting - and none of that memory is needed to see where the process is stuck.
#
# Run it while the game is frozen (do not kill the process first):
#     powershell -ExecutionPolicy Bypass -File grab-hang-dump.ps1
$ErrorActionPreference = 'Stop'

$p = Get-Process 'Bodycam-Win64-Shipping' -ErrorAction SilentlyContinue
if (-not $p) { Write-Host 'Bodycam is not running.' -ForegroundColor Yellow; exit 1 }

$out = Join-Path $PSScriptRoot ('hang_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.dmp')

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class MiniDumper {
  [DllImport("dbghelp.dll", SetLastError = true)]
  public static extern bool MiniDumpWriteDump(IntPtr hProcess, uint pid, IntPtr hFile,
      int dumpType, IntPtr exceptionParam, IntPtr userStreamParam, IntPtr callbackParam);
}
"@

Write-Host "Writing a stacks-only dump of pid $($p.Id) ..."
$sw = [Diagnostics.Stopwatch]::StartNew()
$fs = [System.IO.File]::Create($out)
try {
  # 0 = MiniDumpNormal: enough to walk every thread's stack, which is the whole question.
  $ok = [MiniDumper]::MiniDumpWriteDump($p.Handle, [uint32]$p.Id,
        $fs.SafeFileHandle.DangerousGetHandle(), 0, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
} finally { $fs.Dispose() }
$sw.Stop()

if ($ok) {
  $mb = [math]::Round((Get-Item $out).Length / 1MB, 1)
  Write-Host "Saved $out  ($mb MB in $([math]::Round($sw.Elapsed.TotalSeconds,1)) s)" -ForegroundColor Green
} else {
  Remove-Item $out -ErrorAction SilentlyContinue
  Write-Host "MiniDumpWriteDump failed (win32 $err). Try running this from an elevated PowerShell." -ForegroundColor Red
  exit 1
}
