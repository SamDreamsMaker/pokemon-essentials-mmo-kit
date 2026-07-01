<#
  package-mmo.ps1 — build a clean, shareable copy of the game for a private
  LAN test with a friend, as a single .zip.

  Usage (from anywhere):
      powershell -ExecutionPolicy Bypass -File tools\package-mmo.ps1
      # optional custom output:  -Output "C:\path\PokeMMO.zip"

  What it does:
    - copies the game, EXCLUDING dev-only cruft (.git, docs, tools, logs, the
      debug launcher, editor projects);
    - drops a commented mmo_config.txt template for the recipient to fill in;
    - zips the result.

  IMPORTANT: the plugin runs from Data/PluginScripts.rxdata (compiled). That file
  is (re)built whenever you launch the game in DEBUG (PlayMMO-debug.bat). So after
  ANY change to Plugins/PokeMMO, launch once in debug BEFORE packaging, or the
  build will ship stale plugin code.
#>
param([string]$Output = "")

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # tools/.. = game root
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
if (-not $Output) { $Output = Join-Path ([Environment]::GetFolderPath('Desktop')) "PokeMMO-Build-$stamp.zip" }
$stage = Join-Path $env:TEMP "PokeMMO-stage-$stamp"

Write-Host "Game root : $root"
Write-Host "Output zip: $Output"

$rxdata = Join-Path $root "Data\PluginScripts.rxdata"
if (-not (Test-Path -LiteralPath $rxdata)) {
  Write-Warning "Data\PluginScripts.rxdata missing - launch PlayMMO-debug.bat once so the plugin compiles, then re-run."
}

$excludeDirs  = @(".git", ".claude", "docs", "tools", ".vscode", "Screenshots", "__pycache__")
$excludeFiles = @("mmo.log", "errorlog.txt", "PlayMMO-debug.bat", "PlayMMO-guest.bat", "scripts_extract.rb",
                  "scripts_combine.rb", "*.mkproj", "Game.rxproj", "*.code-workspace",
                  # dev-only tools/config, not needed to play
                  ".gitignore", ".rubocop.yml", "*.URL", "*.url",
                  "animmaker.exe", "animmaker.txt", "extendtext.exe", "extendtext.txt",
                  "townmapgen.html", "knownpoint.bmp", "selpoint.bmp")

Write-Host "Staging (this copies Graphics/Audio, may take a minute)..."
robocopy $root $stage /E /XD $excludeDirs /XF $excludeFiles /NFL /NDL /NJH /NP /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed with code $LASTEXITCODE" }

# Connection-config template for the recipient.
$cfg = @"
# PokeMMO connection config. Uncomment and edit ONE section.
#
# --- Hosting (friends connect to your IP; allow the Windows Firewall prompt) ---
# role = host
# bind = 0.0.0.0
# port = 9998
#
# --- Joining a friend's game ---
# role = client
# host = 192.168.1.42   # the host's LAN IP (host runs: ipconfig)
# port = 9998
#
# Leave everything commented for same-PC auto mode.
"@
Set-Content -LiteralPath (Join-Path $stage "mmo_config.txt") -Value $cfg -Encoding UTF8

if (Test-Path -LiteralPath $Output) { Remove-Item -LiteralPath $Output -Force }
Write-Host "Zipping..."
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $Output -CompressionLevel Optimal
Remove-Item -LiteralPath $stage -Recurse -Force

$sizeMB = [math]::Round((Get-Item -LiteralPath $Output).Length / 1MB, 1)
Write-Host "Done: $Output ($sizeMB MB)"
exit 0
