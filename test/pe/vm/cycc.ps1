# Run on the Windows machine by `ytest cycc-win`: cycc.exe over the jobs of
# <Share>\jobs.txt ("elf PATH" or "S PATH", PATH relative to the repo root), in
# the root copy. Job N leaves res\N.exit and res\N.err, and res\N.out: the ELF it
# wrote, or for "S" the listing on stdout.
param([string]$Share, [int]$Timeout = 180)
$ErrorActionPreference = 'Continue'
$work = Join-Path $env:TEMP 'ytest-cycc-run'
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $work, "$work\res" | Out-Null
robocopy "$Share\root" "$work\root" /E /NFL /NDL /NJH /NJS | Out-Null
Copy-Item "$Share\cycc.exe" "$work\cycc.exe"
New-Item -ItemType Directory "$Share\res" -Force | Out-Null
$n = 0
foreach ($line in Get-Content "$Share\jobs.txt") {
  if ($line.Trim() -eq '') { continue }
  $kind, $path = $line -split ' ', 2
  $o = "$work\res\$n.out"; $e = "$work\res\$n.err"
  if ($kind -eq 'S') { $cmd = "`"$work\cycc.exe`" --emit=asm $path > `"$o`" 2> `"$e`"" }
  else { $cmd = "`"$work\cycc.exe`" $path -o `"$o`" > NUL 2> `"$e`"" }
  $p = Start-Process cmd -ArgumentList "/d /c `"$cmd`"" -WorkingDirectory "$work\root" -PassThru -WindowStyle Hidden
  $null = $p.Handle
  if (-not $p.WaitForExit($Timeout * 1000)) { taskkill /F /T /PID $p.Id | Out-Null; '-998' | Set-Content "$work\res\$n.exit" }
  else { "$($p.ExitCode)" | Set-Content "$work\res\$n.exit" }
  $n++
}
robocopy "$work\res" "$Share\res" /E /NFL /NDL /NJH /NJS | Out-Null
'DONE' | Set-Content "$Share\res\DONE"
