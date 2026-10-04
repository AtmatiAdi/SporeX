<#
.SYNOPSIS
  Eksport gry: build\SporeX.exe (jeden plik, dane wbudowane w exe).

.DESCRIPTION
  Uzywa standardowego Godota (bez .NET - projekt nie ma C#, wiec gra jest
  mniejsza i nie potrzebuje runtime'u). Przy pierwszym uruchomieniu pobiera
  Godota i szablony eksportu do cache (domyslnie %LOCALAPPDATA%\SporeX-build,
  w CI: $env:SPOREX_TOOLS) i rozpakowuje z szablonow tylko pliki Windows.

  Ten sam skrypt odpala release.ps1 -Local i workflow .github/workflows/release.yml.

.PARAMETER Out
  Sciezka wyjsciowa wzgledem katalogu projektu (domyslnie build\SporeX.exe).
#>
param([string]$Out = 'build\SporeX.exe')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest z paskiem jest kilkanascie razy wolniejszy

$GodotVersion = '4.7.2'
$root = Split-Path $PSScriptRoot -Parent
$cache = if ($env:SPOREX_TOOLS) { $env:SPOREX_TOOLS } else { Join-Path $env:LOCALAPPDATA 'SporeX-build' }
$base = "https://github.com/godotengine/godot/releases/download/$GodotVersion-stable"
New-Item -ItemType Directory -Force $cache | Out-Null
# Cache moze lezec w katalogu projektu (CI): Godot ma go pominac przy imporcie.
New-Item -ItemType File -Force (Join-Path $cache ".gdignore") | Out-Null

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# --- Godot (standard, win64) ---------------------------------------------------
$godotDir = Join-Path $cache "godot-$GodotVersion"
$godot = Join-Path $godotDir "Godot_v$GodotVersion-stable_win64_console.exe"
if (-not (Test-Path $godot)) {
    Step "Pobieram Godot $GodotVersion"
    $zip = Join-Path $cache "godot-$GodotVersion.zip"
    Invoke-WebRequest "$base/Godot_v$GodotVersion-stable_win64.exe.zip" -OutFile $zip
    Expand-Archive $zip -DestinationPath $godotDir -Force
    Remove-Item $zip
    if (-not (Test-Path $godot)) { throw "brak $godot po rozpakowaniu" }
}

# --- Szablony eksportu (tylko Windows) ---------------------------------------------
$tplDir = Join-Path $env:APPDATA "Godot\export_templates\$GodotVersion.stable"
if (-not (Test-Path (Join-Path $tplDir 'windows_release_x86_64.exe'))) {
    $tpz = Join-Path $cache "templates-$GodotVersion.tpz"
    if (-not (Test-Path $tpz)) {
        Step "Pobieram szablony eksportu $GodotVersion (duzy plik, tylko raz)"
        Invoke-WebRequest "$base/Godot_v$GodotVersion-stable_export_templates.tpz" -OutFile $tpz
    }
    Step 'Rozpakowuje szablony Windows'
    New-Item -ItemType Directory -Force $tplDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($tpz)
    try {
        foreach ($e in $z.Entries) {
            if ($e.Name -like 'windows_*' -or $e.Name -eq 'version.txt') {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $tplDir $e.Name), $true)
            }
        }
    }
    finally { $z.Dispose() }
}

# --- Import i eksport ------------------------------------------------------------------
Step 'Import projektu (cache klas)'
& $godot --headless --path $root --import 2>&1 | Out-Host
$outPath = Join-Path $root $Out
New-Item -ItemType Directory -Force (Split-Path $outPath) | Out-Null
if (Test-Path $outPath) { Remove-Item $outPath -Force }
Step "Eksport -> $Out"
& $godot --headless --path $root --export-release 'Windows' $outPath 2>&1 | Out-Host
if (-not (Test-Path $outPath)) { throw 'eksport nie utworzyl pliku' }
"{0}  {1:N1} MB" -f $Out, ((Get-Item $outPath).Length / 1MB)
