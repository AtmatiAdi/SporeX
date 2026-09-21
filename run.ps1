param([switch]$Editor, [string[]]$GameArgs)
# Launches SporeX with the Godot 4.7.2 (.NET) build installed by winget.
$godot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages\GodotEngine.GodotEngine.Mono_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_mono_win64\Godot_v4.7.2-stable_mono_win64_console.exe"
if (-not (Test-Path $godot)) {
    $found = Get-Command godot -ErrorAction SilentlyContinue
    if ($found) { $godot = $found.Source } else { Write-Error "Godot not found. Install: winget install GodotEngine.GodotEngine.Mono"; exit 1 }
}
if ($Editor) { & $godot --path $PSScriptRoot --editor }
else { & $godot --path $PSScriptRoot -- @GameArgs }
