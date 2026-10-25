# Run on the Windows machine by `ytest pe-fixtures`: every program of
# <Share>\out as listed in manifest.txt ("name scratch dir" per line), its
# stdout+stderr in <Share>\res\NAME.out and its exit status in NAME.exit
# ("HUNG" when it ran past -Timeout seconds). A program runs from a local copy
# (an SMB share is not a place to test a file system), in a fresh directory when
# `scratch`, else in the copy of the repo root. NAME.args (the raw command line
# tail), NAME.env (K=V lines) and NAME.stdin sit beside the fixture's source.
param([string]$Share, [int]$Timeout = 30)
$ErrorActionPreference = 'Continue'
$work = Join-Path $env:TEMP 'ytest-pe-run'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work, "$work\res", "$work\scratch" | Out-Null
robocopy "$Share\out" "$work\out" /E /NFL /NDL /NJH /NJS | Out-Null
robocopy "$Share\root" "$work\root" /E /NFL /NDL /NJH /NJS | Out-Null
New-Item -ItemType Directory "$Share\res" -Force | Out-Null

function Finish($name, $code) { "$code" | Set-Content "$work\res\$name.exit" }

foreach ($line in Get-Content "$Share\manifest.txt") {
  if ($line.Trim() -eq '') { continue }
  $name, $scratch, $dir = $line -split ' '
  $exe = "$work\out\$name.exe"
  $out = "$work\res\$name.out"
  $src = "$work\root\test\" + ($dir -replace '/', '\')
  $wd = "$work\root"
  if ($scratch -eq '1') { $wd = "$work\scratch\$name"; New-Item -ItemType Directory $wd | Out-Null }
  $stdin = 'NUL'
  if (Test-Path "$src\$name.stdin") { $stdin = "$src\$name.stdin" }

  if ((Test-Path "$src\$name.args") -or (Test-Path "$src\$name.env")) {
    # no shell: the command line and the environment are exactly what the files say
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.WorkingDirectory = $wd
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    if (Test-Path "$src\$name.args") { $psi.Arguments = (Get-Content "$src\$name.args" -Encoding UTF8 -Raw).TrimEnd("`r", "`n") }
    if (Test-Path "$src\$name.env") {
      foreach ($e in Get-Content "$src\$name.env" -Encoding UTF8) {
        $i = $e.IndexOf('=')
        if ($i -gt 0) { $psi.EnvironmentVariables[$e.Substring(0, $i)] = $e.Substring($i + 1) }
      }
    }
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $so = New-Object System.IO.MemoryStream
    $task = $p.StandardOutput.BaseStream.CopyToAsync($so)
    $se = New-Object System.IO.MemoryStream
    $task2 = $p.StandardError.BaseStream.CopyToAsync($se)
    if (-not $p.WaitForExit($Timeout * 1000)) { taskkill /F /T /PID $p.Id | Out-Null; Finish $name 'HUNG'; continue }
    $task.Wait(); $task2.Wait()
    [System.IO.File]::WriteAllBytes($out, $so.ToArray() + $se.ToArray())
    Finish $name $p.ExitCode
    continue
  }

  $p = Start-Process cmd -ArgumentList "/d /c `"`"$exe`" < `"$stdin`" > `"$out`" 2>&1`"" -WorkingDirectory $wd -PassThru -WindowStyle Hidden
  $null = $p.Handle
  if (-not $p.WaitForExit($Timeout * 1000)) { taskkill /F /T /PID $p.Id | Out-Null; Finish $name 'HUNG' }
  else { Finish $name $p.ExitCode }
}

robocopy "$work\res" "$Share\res" /E /NFL /NDL /NJH /NJS | Out-Null
'DONE' | Set-Content "$Share\res\DONE"
