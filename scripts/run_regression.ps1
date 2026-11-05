param([string]$OutputDir = 'run-output')

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$out = if ([IO.Path]::IsPathRooted($OutputDir)) { $OutputDir } else { Join-Path $repo $OutputDir }
if (Test-Path -LiteralPath $out) { throw "Output directory already exists: $out" }
foreach ($tool in @('vlib.exe', 'vlog.exe', 'vsim.exe')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Required simulator tool missing: $tool" }
}
New-Item -ItemType Directory -Path $out | Out-Null
$version = (& vsim -version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Simulator version query failed' }
$version | Set-Content -LiteralPath (Join-Path $out 'simulator-version.txt')
$revision = (& git -C $repo rev-parse HEAD).Trim()
$dirty = [bool](@(git -C $repo status --porcelain).Count)

Push-Location $out
try {
    & vlib work 2>&1 | Tee-Object -FilePath 'library.log'
    if ($LASTEXITCODE -ne 0) { throw 'Library creation failed' }
    & vlog -sv (Join-Path $repo 'rtl/axi4_dma_subsystem.sv') (Join-Path $repo 'tb/tb_dma_portable.sv') 2>&1 |
        Tee-Object -FilePath 'compile.log'
    if ($LASTEXITCODE -ne 0) { throw 'Compilation failed' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command vsim.exe).Source
    $psi.WorkingDirectory = $out
    $psi.Arguments = '-c -onfinish exit tb_dma_portable -do "onerror {quit -code 1}; run -all; quit -code 0"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $start = Get-Date
    $proc = [Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit(120000)
    if (-not $finished) { $proc.Kill(); $proc.WaitForExit() }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $out 'simulation.log'), $stdout + $stderr)
    $elapsed = [math]::Round(((Get-Date) - $start).TotalSeconds, 2)
    if (-not $finished) { throw 'Simulation timed out after 120 seconds' }
    if ($proc.ExitCode -ne 0) { throw "Simulator exited $($proc.ExitCode)" }
    if ($stdout -match '(?im)^\s*#?\s*\*\*\s+(Error|Fatal):' -or
        $stdout -notmatch '\$finish' -or
        $stdout -notmatch '(?m)^# Errors: 0, Warnings: 0') {
        throw 'Simulation log contains error/fatal or lacks finish/zero-error summary'
    }
    $match = [regex]::Match($stdout, 'DMA_REGRESSION_PASS cases=(\d+) checks=(\d+) seed=0x([0-9A-Fa-f]+)')
    if (-not $match.Success -or [int]$match.Groups[1].Value -lt 20 -or
        [int]$match.Groups[2].Value -le 0) {
        throw 'Expected DMA check summary missing or incomplete'
    }
    $result = [ordered]@{
        status = 'PASS'
        source_revision = $revision
        dirty_source = $dirty
        simulator_version = $version
        command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/run_regression.ps1 -OutputDir <fresh-directory>'
        seed = ('0x' + $match.Groups[3].Value)
        cases = [int]$match.Groups[1].Value
        checks = [int]$match.Groups[2].Value
        simulator_exit_code = $proc.ExitCode
        wrapper_exit_code = 0
        elapsed_seconds = $elapsed
        simulation_log = (Join-Path $out 'simulation.log')
    }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
    Write-Output "DMA_REGRESSION_PASS cases=$($result.cases) checks=$($result.checks) seed=$($result.seed) revision=$revision dirty=$dirty output=$out"
} finally {
    Pop-Location
}
