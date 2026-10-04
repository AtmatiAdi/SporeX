<#
.SYNOPSIS
  Wydanie SporeX: wersja -> tag -> GitHub Release (SporeX.exe, SporeX-Setup.exe, SHA256SUMS.txt).

.DESCRIPTION
  Wzorowane na release.ps1 z SpectreNotes.

  Domyslnie (zalecane):
    1. podnosi config/version w project.godot (i wersje pliku w export_presets.cfg),
    2. commit "Wydanie vX.Y.Z", tag vX.Y.Z, push,
    3. GitHub Actions (.github/workflows/release.yml) eksportuje gre, buduje
       instalator, liczy sumy i publikuje wydanie.

  -Local robi kroki 3 na tym komputerze (tools\export.ps1 + cargo) i sam
  wywoluje `gh release create` - gdy CI nie dziala albo trzeba szybko.

  Zasoby maja stale nazwy, wiec adres najnowszego instalatora sie nie zmienia:
    https://github.com/<repo>/releases/latest/download/SporeX-Setup.exe
  Zainstalowane gry widza nowe wydanie same (HUD: "dostepna wersja ... F12").

  Wymaga: gh (zalogowany), czyste drzewo robocze na main; dla -Local: cargo.

.PARAMETER Version
  Pelny numer, np. 0.2.0. Alternatywa: -Bump.
.PARAMETER Bump
  patch | minor | major.
.PARAMETER Notes
  Opis wydania (markdown). Domyslnie: lista commitow od poprzedniego tagu v*.
.PARAMETER Keep
  Ile ostatnich wydan zostawic na GitHubie (domyslnie 3; tagi zostaja).
.PARAMETER Local
  Zbuduj i opublikuj z tego komputera zamiast przez GitHub Actions.
.PARAMETER DryRun
  Tylko lokalny build i sumy (z -Local) albo sam podglad (bez -Local); bez commitu i pushu.

.EXAMPLE
  .\release.ps1 -Bump patch
  .\release.ps1 -Version 0.2.0 -Notes "Multiplayer LAN" -Local
#>
param(
    [string]$Version,
    [ValidateSet('patch', 'minor', 'major')]
    [string]$Bump,
    [string]$Notes,
    [int]$Keep = 3,
    [switch]$Local,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Set-Location $root
$cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
if ($env:Path -notlike "*$cargoBin*") { $env:Path = "$cargoBin;$env:Path" }

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Fail($msg) { Write-Host "BLAD: $msg" -ForegroundColor Red; exit 1 }

# --- Wersja ------------------------------------------------------------------
$projFile = Join-Path $root 'project.godot'
$proj = Get-Content $projFile -Raw
$m = [regex]::Match($proj, '(?m)^config/version="(\d+)\.(\d+)\.(\d+)"')
if (-not $m.Success) { Fail 'nie znalazlem config/version w project.godot' }
$cur = "$($m.Groups[1].Value).$($m.Groups[2].Value).$($m.Groups[3].Value)"
if ($Bump) {
    $a = [int]$m.Groups[1].Value; $b = [int]$m.Groups[2].Value; $c = [int]$m.Groups[3].Value
    switch ($Bump) {
        'major' { $a++; $b = 0; $c = 0 }
        'minor' { $b++; $c = 0 }
        'patch' { $c++ }
    }
    $Version = "$a.$b.$c"
}
if (-not $Version) { Fail 'podaj -Version X.Y.Z albo -Bump patch|minor|major' }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { Fail "wersja `"$Version`" nie jest X.Y.Z" }
$tag = "v$Version"

# Repozytorium wydan: jedno zrodlo prawdy - stala w instalatorze.
$setupMain = Get-Content (Join-Path $root 'tools\setup\src\main.rs') -Raw
$repo = [regex]::Match($setupMain, '(?m)^pub const RELEASES_REPO: &str = "([^"]+)";').Groups[1].Value
if (-not $repo) { Fail 'brak RELEASES_REPO w tools\setup\src\main.rs' }
Write-Host "SporeX $cur -> $Version  ($repo, tag $tag, $(if ($Local) { 'build lokalny' } else { 'build w GitHub Actions' }))" -ForegroundColor Green

# --- Warunki wstepne ----------------------------------------------------------
Step 'Warunki wstepne'
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { Fail 'brak gh (GitHub CLI)' }
gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Fail 'gh nie jest zalogowany (gh auth login)' }
if ($Local -and -not (Get-Command cargo -ErrorAction SilentlyContinue)) { Fail 'brak cargo (instalator jest w Ruscie)' }
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
if ($branch -ne 'main' -and -not $DryRun) { Fail "wydania tylko z main (jestes na $branch)" }
$dirty = git status --porcelain
if ($dirty -and -not $DryRun) { Fail "drzewo robocze nie jest czyste:`n$dirty" }
if (-not $DryRun -and (git tag -l $tag)) { Fail "tag $tag juz istnieje" }

# --- Wersja do plikow ---------------------------------------------------------
function Set-Version {
    Step "project.godot: config/version=`"$Version`""
    $p = $proj.Substring(0, $m.Groups[1].Index) + $Version + $proj.Substring($m.Groups[3].Index + $m.Groups[3].Length)
    [IO.File]::WriteAllText($projFile, $p, [Text.UTF8Encoding]::new($false))
    $presetFile = Join-Path $root 'export_presets.cfg'
    $preset = Get-Content $presetFile -Raw
    $preset = $preset -replace '(?m)^application/(file|product)_version="[^"]*"', "application/`$1_version=`"$Version.0`""
    [IO.File]::WriteAllText($presetFile, $preset, [Text.UTF8Encoding]::new($false))
    $cargoFile = Join-Path $root 'tools\setup\Cargo.toml'
    $cargo = Get-Content $cargoFile -Raw
    $cargo = ([regex]'(?m)^version = "[^"]*"').Replace($cargo, "version = `"$Version`"", 1)   # tylko pierwsze (pakiet), nie zaleznosci
    [IO.File]::WriteAllText($cargoFile, $cargo, [Text.UTF8Encoding]::new($false))
}

function Get-Notes {
    if ($Notes) { return $Notes }
    $prev = git tag -l 'v*' --sort=-v:refname | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Select-Object -First 1
    $range = if ($prev) { "$prev..HEAD" } else { 'HEAD' }
    $log = git log $range --no-merges --format='- %s'
    if ($log) { return ($log -join "`n") } else { return "SporeX $Version" }
}

Set-Version

if (-not $Local) {
    if ($DryRun) {
        Step 'DryRun - koniec (bez commitu)'
        git checkout -- project.godot export_presets.cfg tools/setup/Cargo.toml
        exit 0
    }
    Step "Commit, tag $tag, push - reszte robi GitHub Actions"
    git add project.godot export_presets.cfg tools/setup/Cargo.toml
    git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) { git commit -q -m "Wydanie $tag" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" }
    git tag -a $tag -m "SporeX $Version"
    git push -q origin main
    git push -q origin $tag
    if ($LASTEXITCODE -ne 0) { Fail 'push nie przeszedl' }
    Write-Host "`nTag wypchniety. Build: https://github.com/$repo/actions" -ForegroundColor Green
    Write-Host "Wydanie pojawi sie po ~5-10 min: https://github.com/$repo/releases/tag/$tag"
    exit 0
}

# --- Build lokalny ------------------------------------------------------------
Step 'Eksport gry'
& (Join-Path $root 'tools\export.ps1')
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { Fail 'eksport nie przeszedl' }
Step 'Instalator (cargo build --release)'
Push-Location (Join-Path $root 'tools\setup')
cargo test --release --quiet
if ($LASTEXITCODE -ne 0) { Pop-Location; Fail 'testy instalatora nie przeszly' }
cargo build --release
if ($LASTEXITCODE -ne 0) { Pop-Location; Fail 'build instalatora nie przeszedl' }
Pop-Location

Step 'Zasoby wydania'
$dist = Join-Path $root 'build\dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Get-ChildItem $dist | Remove-Item -Force
Copy-Item (Join-Path $root 'build\SporeX.exe') $dist
Copy-Item (Join-Path $root 'tools\setup\target\release\SporeX-Setup.exe') $dist
$assets = @('SporeX.exe', 'SporeX-Setup.exe')
$sums = $assets | ForEach-Object { "{0}  {1}" -f (Get-FileHash (Join-Path $dist $_) -Algorithm SHA256).Hash.ToLower(), $_ }
[IO.File]::WriteAllText((Join-Path $dist 'SHA256SUMS.txt'), (($sums -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
Get-ChildItem $dist | ForEach-Object { "{0,-20} {1,14:N0} B" -f $_.Name, $_.Length }

Step 'Skan Microsoft Defender'
$mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
if (Test-Path $mp) {
    foreach ($a in $assets) {
        $out = (& $mp -Scan -ScanType 3 -File (Join-Path $dist $a) 2>&1 | Out-String)
        if ($out -match 'found no threats') { "$a - czysty" }
        elseif ($out -match 'Threat|found\s+\d|was detected') { Write-Host $out; Fail "Defender zglasza $a - zglos falszywy alarm i nie wydawaj tego pliku" }
        else { Write-Host "$a - skan sie nie wykonal, pomijam" -ForegroundColor Yellow }
    }
}

$text = (Get-Notes) + "`n`nInstalacja: pobierz **SporeX-Setup.exe** i uruchom - pobiera te wersje i instaluje gre dla biezacego uzytkownika (bez administratora). Zainstalowana gra sama pokaze kolejne wydania (F12)."
if ($DryRun) {
    Step 'DryRun - koniec'
    Write-Host $text
    git checkout -- project.godot export_presets.cfg tools/setup/Cargo.toml
    exit 0
}

Step "Commit i tag $tag"
git add project.godot export_presets.cfg tools/setup/Cargo.toml
git diff --cached --quiet
if ($LASTEXITCODE -ne 0) { git commit -q -m "Wydanie $tag" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>" }
git tag -a $tag -m "SporeX $Version"
git push -q origin main
git push -q origin $tag
if ($LASTEXITCODE -ne 0) { Fail 'push nie przeszedl' }

Step "gh release create $tag"
$notesFile = Join-Path $dist 'NOTES.md'
[IO.File]::WriteAllText($notesFile, $text, [Text.UTF8Encoding]::new($false))
gh release create $tag (Join-Path $dist 'SporeX.exe') (Join-Path $dist 'SporeX-Setup.exe') (Join-Path $dist 'SHA256SUMS.txt') `
    --repo $repo --title "SporeX $Version" --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { Fail 'gh release create nie przeszedl' }
Remove-Item $notesFile

Step "Zostawiam $Keep ostatnich wydan"
$all = gh release list --repo $repo --limit 100 --json tagName,createdAt,isDraft | ConvertFrom-Json
$old = $all | Where-Object { -not $_.isDraft } | Sort-Object { [datetime]$_.createdAt } -Descending | Select-Object -Skip $Keep
foreach ($r in $old) { Write-Host "  usuwam wydanie $($r.tagName) (tag zostaje)"; gh release delete $r.tagName --repo $repo --yes }

Write-Host "`nWydano SporeX $Version" -ForegroundColor Green
Write-Host "  https://github.com/$repo/releases/tag/$tag"
Write-Host "  instalator: https://github.com/$repo/releases/latest/download/SporeX-Setup.exe"
