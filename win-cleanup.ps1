# DiskReport.ps1 - report of what is filling C:, then pick what to delete.
#
# Run:  powershell -ExecutionPolicy Bypass -File .\DiskReport.ps1
# It restarts itself as Administrator. The report is saved to your Desktop.
# Nothing is deleted until you pick items AND type DELETE to confirm.
# Windows, Program Files, ProgramData, app settings, OneDrive, SSH keys and
# virtual disk files are never offered for deletion.

param([string]$UserProfile = $env:USERPROFILE)

# ---------- elevate ----------
$me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Restarting as Administrator...'
    Start-Process powershell.exe -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
        '-File', "`"$PSCommandPath`"", '-UserProfile', "`"$UserProfile`"")
    exit
}

$ErrorActionPreference = 'SilentlyContinue'
$Local   = Join-Path $UserProfile 'AppData\Local'
$Roaming = Join-Path $UserProfile 'AppData\Roaming'
$report  = Join-Path $UserProfile 'Desktop\C_Drive_Report.txt'
$bigFiles = New-Object System.Collections.Generic.List[object]
$BigFileThreshold = 500MB
$script:Skipped = 0

# ---------- helpers ----------
function Free { [System.IO.DriveInfo]::new('C').AvailableFreeSpace }
function Fmt([double]$b) {
    if ($b -ge 1TB) { '{0,8:N2} TB' -f ($b / 1TB) }
    elseif ($b -ge 1GB) { '{0,8:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0,8:N1} MB' -f ($b / 1MB) }
    else { '{0,8:N0} KB' -f ($b / 1KB) }
}
function Out([string]$line = '') { Write-Host $line; Add-Content -Path $report -Value $line }

function Get-DirSize([string]$path) {
    # Skips junctions/symlinks so nothing is counted twice; unreadable folders are skipped, not fatal.
    $total = [long]0
    if (-not (Test-Path -LiteralPath $path)) { return $total }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($path)
    while ($stack.Count -gt 0) {
        $di = New-Object System.IO.DirectoryInfo ($stack.Pop())
        try {
            foreach ($f in $di.GetFiles()) {
                $total += $f.Length
                if ($f.Length -ge $BigFileThreshold) { $bigFiles.Add([pscustomobject]@{ Size = $f.Length; Path = $f.FullName }) }
            }
        } catch { }
        try {
            foreach ($s in $di.GetDirectories()) {
                if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $stack.Push($s.FullName) }
            }
        } catch { }
    }
    return $total
}

# ---------- what may never be deleted ----------
$ProtectedExact = @('C:\', 'C:\Users', $UserProfile, "$UserProfile\AppData", $Local, $Roaming, "$UserProfile\AppData\LocalLow")
$ProtectedPrefixes = @('C:\Windows', 'C:\Windows.old', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData',
    'C:\System Volume Information', 'C:\Recovery', 'C:\$Recycle.Bin', 'C:\Config.Msi', 'C:\Boot', 'C:\EFI',
    "$UserProfile\OneDrive", "$Local\Packages", "$Local\Docker", "$Local\Microsoft", "$Roaming\Microsoft")
$ProtectedNames = @('.ssh', '.aws', '.azure', '.kube', '.docker', '.gnupg', '.config', '.gitconfig', 'AppData')
$ProtectedExt = @('.vhdx', '.vhd', '.vdi', '.sys')

function Test-Protected([string]$p) {
    $n = $p.TrimEnd('\')
    if ($n.Length -le 3) { return $true }
    foreach ($e in $ProtectedExact) { if ($n -ieq $e.TrimEnd('\')) { return $true } }
    foreach ($x in $ProtectedPrefixes) {
        if ($n -ieq $x -or $n.StartsWith($x + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    $leaf = Split-Path $n -Leaf
    if ($ProtectedNames -contains $leaf -or $leaf -like 'ntuser*') { return $true }
    if ($ProtectedExt -contains [IO.Path]::GetExtension($n).ToLower()) { return $true }
    return $false
}

# ---------- candidate list for the picker ----------
$Candidates = New-Object System.Collections.Generic.List[object]
function Add-Candidate([long]$Size, [string]$Kind, [string]$Item, [string]$Note, [string]$Arg = '', [int]$Order = 50) {
    if ($Kind -in 'Folder', 'File', 'Contents' -and (Test-Protected $Item)) { return }
    foreach ($c in $Candidates) { if ($c.Item -ieq $Item) { return } }
    $label = switch ($Kind) { 'Folder' { 'Delete folder' } 'File' { 'Delete file' } 'Contents' { 'Empty folder' } default { 'Action' } }
    $Candidates.Add([pscustomobject]@{
        Id = $Candidates.Count + 1; SizeGB = [math]::Round($Size / 1GB, 2); Type = $label
        Item = $Item; Note = $Note; Kind = $Kind; Arg = $Arg; Order = $Order })
}

$KnownNotes = @{
    'pinokio'            = 'Pinokio AI apps + models. Uninstall apps inside Pinokio to be selective.'
    'texlive'            = 'LaTeX install. Only if you no longer use LaTeX.'
    'nvm4w'              = 'Node version manager link. Deleting breaks node/npm.'
    'Apple'              = 'iPhone backups. Make sure you have iCloud or another backup first.'
    'locally-uncensored' = 'Local AI model files (re-downloadable).'
    '.vscode'            = 'VS Code extensions (reinstall from the marketplace).'
    '.bun'               = 'Bun runtime + cache.'
    '.cache'             = 'Misc tool caches (usually re-created).'
    '.local'             = 'Per-user installed tools (pipx/uv tools). Those tools stop working.'
    '.nuget'             = 'NuGet package cache (re-downloads).'
    '.gradle'            = 'Gradle caches (re-download).'
    '.m2'                = 'Maven repository (re-downloads).'
    '.ollama'            = 'Ollama models (re-downloadable).'
    '.android'           = 'Android emulators/settings.'
    'work'               = 'Looks like your projects - careful.'
}
$KnownFolders = @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'Contacts', 'Favorites',
                  'Links', 'Saved Games', 'Searches', '3D Objects')

function Get-FileNote([string]$path) {
    $ext = [IO.Path]::GetExtension($path).ToLower()
    if ($path -like '*\Comfy-Desktop\*\models\*') { return 'ComfyUI model (re-downloadable if you need it again)' }
    switch -Regex ($ext) {
        '^\.(safetensors|gguf|ckpt|pt|pth|bin|onnx)$' { 'AI model / weights file (re-downloadable)' }
        '^\.(zip|7z|rar|iso|exe|msi)$'                { 'Archive / installer - safe if already installed or extracted' }
        '^\.(mp4|mov|mkv|avi)$'                       { 'Your video - move it elsewhere if you want to keep it' }
        '^\.(nvph)$'                                  { 'NVIDIA shader cache (rebuilds)' }
        default                                       { '' }
    }
}

function ConvertFrom-DockerSize([string]$s) {
    if ($s -match '([\d\.]+)\s*([kKMGT]?B)') {
        $n = [double]$matches[1]
        switch ($matches[2]) { 'kB' { $n * 1KB } 'MB' { $n * 1MB } 'GB' { $n * 1GB } 'TB' { $n * 1TB } default { $n } }
    } else { 0 }
}

function Get-WslDistros {
    Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss' | ForEach-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath
        if ($p.DistributionName -and $p.BasePath) {
            $base = $p.BasePath -replace '^\\\\\?\\', ''
            $file = if ($p.VhdFileName) { $p.VhdFileName } else { 'ext4.vhdx' }
            [pscustomobject]@{ Name = $p.DistributionName; Vhdx = (Join-Path $base $file) }
        }
    }
}

# =====================================================================
#                              REPORT
# =====================================================================
Set-Content -Path $report -Value "C: drive report - $(Get-Date)"

# 1. Drive summary
$drive = [System.IO.DriveInfo]::new('C')
Out ''
Out '=== DRIVE C: ==='
Out ("Used: {0}   Free: {1}   Total: {2}" -f (Fmt ($drive.TotalSize - $drive.AvailableFreeSpace)).Trim(), (Fmt $drive.AvailableFreeSpace).Trim(), (Fmt $drive.TotalSize).Trim())

# 2. Top-level folders and root files
Out ''
Out '=== TOP-LEVEL FOLDERS ON C:\ (this can take several minutes) ==='
$top = New-Object System.Collections.Generic.List[object]
foreach ($d in (New-Object System.IO.DirectoryInfo 'C:\').GetDirectories()) {
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
    Write-Host "  scanning $($d.FullName)..." -ForegroundColor DarkGray
    $size = [long]0
    try { $size = Get-DirSize $d.FullName } catch { }
    $top.Add([pscustomobject]@{ Size = $size; Path = $d.FullName; IsFile = $false })
}
foreach ($f in (New-Object System.IO.DirectoryInfo 'C:\').GetFiles()) {
    $top.Add([pscustomobject]@{ Size = $f.Length; Path = $f.FullName; IsFile = $true })
}
foreach ($t in ($top | Sort-Object Size -Descending)) {
    Out ("{0}  {1}{2}" -f (Fmt $t.Size), $t.Path, $(if ($t.IsFile) { '  (file)' } else { '' }))
    if (-not $t.IsFile) { Add-Candidate $t.Size 'Folder' $t.Path $KnownNotes[(Split-Path $t.Path -Leaf)] }
}

# 3. User profile breakdown
Out ''
Out "=== INSIDE YOUR USER FOLDER ($UserProfile) ==="
$userItems = New-Object System.Collections.Generic.List[object]
foreach ($d in (Get-ChildItem -LiteralPath $UserProfile -Directory -Force)) {
    if ($d.Name -eq 'AppData' -or ($d.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
    $userItems.Add([pscustomobject]@{ Size = (Get-DirSize $d.FullName); Path = $d.FullName; Name = $d.Name })
}
foreach ($n in 'Local', 'Roaming', 'LocalLow') {
    $p = Join-Path "$UserProfile\AppData" $n
    $userItems.Add([pscustomobject]@{ Size = (Get-DirSize $p); Path = $p; Name = $n })
}
foreach ($u in ($userItems | Sort-Object Size -Descending | Select-Object -First 25)) {
    Out ("{0}  {1}" -f (Fmt $u.Size), $u.Path)
    if ($u.Size -lt 50MB) { continue }
    if ($KnownFolders -contains $u.Name) { Add-Candidate $u.Size 'Contents' $u.Path 'Empties this folder (the folder itself stays)' }
    else { Add-Candidate $u.Size 'Folder' $u.Path $KnownNotes[$u.Name] }
}

# 4. Biggest folders inside AppData\Local (info only - app data is not offered as a whole)
Out ''
Out '=== BIGGEST FOLDERS IN AppData\Local ==='
Get-ChildItem -LiteralPath $Local -Directory -Force |
    ForEach-Object { [pscustomobject]@{ Size = (Get-DirSize $_.FullName); Path = $_.FullName } } |
    Sort-Object Size -Descending | Select-Object -First 15 |
    ForEach-Object { Out ("{0}  {1}" -f (Fmt $_.Size), $_.Path) }

# 5. Docker & WSL
Out ''
Out '=== DOCKER / WSL VIRTUAL DISKS (.vhdx) ==='
$distros = @(Get-WslDistros)
$vhdx = @(Get-ChildItem -LiteralPath "$Local\Docker\wsl" -Recurse -Filter *.vhdx -File -Force) +
        @($distros | ForEach-Object { Get-Item -LiteralPath $_.Vhdx -Force })
$vhdx = $vhdx | Where-Object { $_ } | Sort-Object FullName -Unique
if ($vhdx) { $vhdx | Sort-Object Length -Descending | ForEach-Object { Out ("{0}  {1}" -f (Fmt $_.Length), $_.FullName) } }
else { Out '  none found' }
if ($vhdx) {
    Add-Candidate (($vhdx | Measure-Object Length -Sum).Sum) 'Cmd' 'Shrink Docker + WSL disk files' `
        'Returns space freed inside Docker/WSL to C:. Shuts down Docker Desktop and WSL. Files inside are kept.' 'CompactDisks' 90
}

if (Get-Command wsl.exe -ErrorAction SilentlyContinue) {
    Out ''
    Out '--- WSL distros (wsl -l -v) ---'
    ((wsl.exe -l -v) -replace "`0", '') | Where-Object { $_.Trim() } | ForEach-Object { Out "  $_" }
    foreach ($d in $distros) {
        if ($d.Name -like 'docker-desktop*') { continue }
        $sz = (Get-Item -LiteralPath $d.Vhdx -Force).Length
        Add-Candidate $sz 'Cmd' "Remove WSL distro '$($d.Name)'" 'PERMANENTLY deletes this Linux install and every file in it.' $d.Name 80
    }
}

$dockerOk = $false
if (Get-Command docker -ErrorAction SilentlyContinue) {
    docker info *> $null
    $dockerOk = ($LASTEXITCODE -eq 0)
    Out ''
    Out '--- Docker usage (docker system df) ---'
    if ($dockerOk) {
        docker system df 2>&1 | ForEach-Object { Out "  $_" }
        $df = @{}
        docker system df --format '{{.Type}}|{{.Reclaimable}}' | ForEach-Object {
            $parts = $_ -split '\|'; $df[$parts[0]] = $parts[1]
        }
        Add-Candidate (ConvertFrom-DockerSize $df['Images']) 'Cmd' 'Docker: stopped containers + unused images' `
            'Re-download/rebuild when needed. Skip if you have images you cannot rebuild.' 'DockerImages' 10
        Add-Candidate (ConvertFrom-DockerSize $df['Build Cache']) 'Cmd' 'Docker: build cache' 'Always safe; builds just run slower once.' 'DockerBuild' 10
        Add-Candidate (ConvertFrom-DockerSize $df['Local Volumes']) 'Cmd' 'Docker: unused volumes' `
            'Can contain DATABASE data from old projects. Only if you do not need it.' 'DockerVolumes' 11
    } else { Out '  Docker is not running - start Docker Desktop and re-run to get Docker cleanup options.' }
}

# 6. Common space hogs
Out ''
Out '=== COMMON SPACE HOGS ==='
$hogs = @(
    # label, path, kind, arg, note
    @('Downloads',                        "$UserProfile\Downloads",                  'Contents', '',            'Empties Downloads - look through it first'),
    @('Your Temp folder',                 "$Local\Temp",                             'Cmd',      'Temp',        'Temp files older than 1 day'),
    @('Windows Temp',                     'C:\Windows\Temp',                         'Cmd',      'Temp',        'Temp files older than 1 day'),
    @('Recycle Bin',                      'C:\$Recycle.Bin',                         'Cmd',      'RecycleBin',  'Empties the Recycle Bin'),
    @('Windows Update downloads',         'C:\Windows\SoftwareDistribution\Download','Cmd',      'WinUpdate',   'Already-installed update downloads'),
    @('Windows Installer cache',          'C:\Windows\Installer',                    'Info',     '',            ''),
    @('Windows component store (WinSxS)', 'C:\Windows\WinSxS',                       'Cmd',      'Dism',        'Safe Windows cleanup of superseded components (slow)'),
    @('Crash dumps',                      "$Local\CrashDumps",                       'Contents', '',            'App crash dumps'),
    @('NVIDIA shader cache',              "$Local\NVIDIA\DXCache",                   'Contents', '',            'Rebuilds automatically'),
    @('NVIDIA GL cache',                  "$Local\NVIDIA\GLCache",                   'Contents', '',            'Rebuilds automatically'),
    @('npm cache',                        "$Local\npm-cache",                        'Cmd',      'Npm',         'Re-downloads as needed'),
    @('pnpm store',                       "$Local\pnpm",                             'Cmd',      'Pnpm',        'Removes packages no project uses'),
    @('pip cache',                        "$Local\pip\Cache",                        'Cmd',      'Pip',         'Re-downloads as needed'),
    @('uv cache',                         "$Local\uv",                               'Cmd',      'Uv',          'Re-downloads as needed'),
    @('Cypress binaries',                 "$Local\Cypress\Cache",                    'Contents', '',            "Run 'npx cypress install' if needed again"),
    @('ComfyUI installer cache',          "$Local\Comfy-Desktop\ComfyUI-Cache\download-cache", 'Contents', '',  'Installer downloads, not your models'),
    @('FiveM cache',                      "$Local\FiveM\FiveM.app\data\cache",       'Contents', '',            'Re-downloads when you join servers'),
    @('FiveM server cache',               "$Local\FiveM\FiveM.app\data\server-cache-priv", 'Contents', '',      'Re-downloads when you join servers'),
    @('Browser caches',                   "$Local\Google\Chrome\User Data",          'Cmd',      'Browsers',    'Cache only - logins, bookmarks, passwords kept. Close browsers first.'),
    @('Chrome Canary AI model',           "$Local\Google\Chrome SxS\User Data\OptGuideOnDeviceModel", 'Folder', '', 'Canary re-downloads it if you use its AI features'),
    @('NuGet packages',                   "$UserProfile\.nuget\packages",            'Contents', '',            'Re-downloads as needed'),
    @('Gradle cache',                     "$UserProfile\.gradle\caches",             'Contents', '',            'Re-downloads as needed'),
    @('Maven repo',                       "$UserProfile\.m2\repository",             'Contents', '',            'Re-downloads as needed'),
    @('Hugging Face models',              "$UserProfile\.cache\huggingface",         'Contents', '',            'Re-downloadable models'),
    @('Ollama models',                    "$UserProfile\.ollama\models",             'Contents', '',            'Re-downloadable models'),
    @('Steam games',                      'C:\Program Files (x86)\Steam\steamapps',  'Info',     '',            ''),
    @('OneDrive (local copies)',          "$UserProfile\OneDrive",                   'Info',     '',            '')
)
foreach ($h in $hogs) {
    $label, $path, $kind, $arg, $note = $h
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $sz = Get-DirSize $path
    Out ("{0}  {1}  [{2}]" -f (Fmt $sz), $label, $path)
    if ($sz -lt 10MB -or $kind -eq 'Info') { continue }
    if ($kind -eq 'Cmd') { Add-Candidate $sz 'Cmd' $label $note $arg }
    else { Add-Candidate $sz $kind $path $note }
}

# Clipchamp (stored under Packages, so offered as a reset)
$clip = Get-ChildItem -LiteralPath "$Local\Packages" -Directory -Filter 'Clipchamp.Clipchamp_*' | Select-Object -First 1
if ($clip) {
    $sz = Get-DirSize $clip.FullName
    Out ("{0}  Clipchamp local data  [{1}]" -f (Fmt $sz), $clip.FullName)
    if ($sz -gt 100MB) { Add-Candidate $sz 'Cmd' 'Reset Clipchamp' 'Deletes imported media copies AND local projects - export first.' 'Clipchamp' }
}

# iPhone backups, one entry per backup
foreach ($b in @("$UserProfile\Apple\MobileSync\Backup", "$Roaming\Apple Computer\MobileSync\Backup")) {
    if (-not (Test-Path -LiteralPath $b)) { continue }
    foreach ($d in (Get-ChildItem -LiteralPath $b -Directory -Force)) {
        $sz = Get-DirSize $d.FullName
        Out ("{0}  iPhone backup from {1:yyyy-MM-dd}  [{2}]" -f (Fmt $sz), $d.LastWriteTime, $d.FullName)
        Add-Candidate $sz 'Folder' $d.FullName ("iPhone backup, last updated {0:yyyy-MM-dd}. Keep at least one backup somewhere." -f $d.LastWriteTime)
    }
}

foreach ($f in 'C:\hiberfil.sys', 'C:\pagefile.sys', 'C:\swapfile.sys') {
    $i = Get-Item -LiteralPath $f -Force
    if ($i) { Out ("{0}  {1}" -f (Fmt $i.Length), $f) }
}
$hib = Get-Item -LiteralPath 'C:\hiberfil.sys' -Force
if ($hib) { Add-Candidate $hib.Length 'Cmd' 'Turn off hibernation (hiberfil.sys)' 'Lose Hibernate + Fast Startup; Sleep/Shut down still work.' 'Hibernate' }

# 7. Largest files
Out ''
Out "=== LARGEST FILES ON C: (over $((Fmt $BigFileThreshold).Trim())) ==="
foreach ($b in ($bigFiles | Sort-Object Path -Unique | Sort-Object Size -Descending | Select-Object -First 40)) {
    Out ("{0}  {1}" -f (Fmt $b.Size), $b.Path)
    Add-Candidate $b.Size 'File' $b.Path (Get-FileNote $b.Path)
}
Out ''
Out "Report saved to: $report"

# =====================================================================
#                               PICKER
# =====================================================================
if ($Candidates.Count -eq 0) { Write-Host "`nNothing to offer for deletion."; return }

$view = $Candidates | Sort-Object SizeGB -Descending | Select-Object Id, SizeGB, Type, Item, Note
$selected = @()
Write-Host "`nOpening the selection window. Ctrl+click or Shift+click to pick several, then press OK." -ForegroundColor Cyan
Write-Host '(Sizes are approximate. Folders under Windows/Program Files/app settings are never listed.)' -ForegroundColor DarkGray
$picked = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
    try { $picked = $view | Out-GridView -Title 'Select what to DELETE, then press OK (Cancel = nothing)' -PassThru -ErrorAction Stop }
    catch { $picked = 'console' }
} else { $picked = 'console' }

if ($picked -eq 'console') {
    $view | Format-Table Id, SizeGB, Type, Item, Note -AutoSize -Wrap | Out-Host
    $raw = Read-Host 'Enter the Ids to delete (e.g. 1,4,7-10), or press Enter to cancel'
    $ids = foreach ($part in ($raw -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { [int]$matches[1]..[int]$matches[2] }
        elseif ($part -match '^\d+$') { [int]$part }
    }
    $selected = @($Candidates | Where-Object { $ids -contains $_.Id })
} elseif ($picked) {
    $ids = @($picked | ForEach-Object Id)
    $selected = @($Candidates | Where-Object { $ids -contains $_.Id })
}

if ($selected.Count -eq 0) { Write-Host "`nNothing selected. Nothing was deleted."; return }

Write-Host "`nYou selected:" -ForegroundColor Yellow
$selected | Sort-Object Order | Format-Table SizeGB, Type, Item, Note -AutoSize -Wrap | Out-Host
Write-Host ("About {0:N1} GB in total." -f (($selected | Measure-Object SizeGB -Sum).Sum)) -ForegroundColor Yellow
Write-Host 'Deleted files do NOT go to the Recycle Bin.' -ForegroundColor Red
if ((Read-Host 'Type DELETE to go ahead') -cne 'DELETE') { Write-Host 'Cancelled. Nothing was deleted.'; return }

# =====================================================================
#                              DELETE
# =====================================================================
function Remove-PathSafe([string]$p) {
    if (-not $p -or (Test-Protected $p) -or -not (Test-Path -LiteralPath $p)) { return }
    $item = Get-Item -LiteralPath $p -Force
    if ($item.PSIsContainer) { cmd.exe /c "rd /s /q `"$p`"" 2>$null | Out-Null }
    else { Remove-Item -LiteralPath $p -Force }
    if (Test-Path -LiteralPath $p) { $script:Skipped++ }
}
function Remove-Contents([string]$path, [int]$olderThanDays = 0) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $cut = (Get-Date).AddDays(-$olderThanDays)
    Get-ChildItem -LiteralPath $path -Force |
        Where-Object { $olderThanDays -eq 0 -or $_.LastWriteTime -lt $cut } |
        ForEach-Object { Remove-PathSafe $_.FullName }
}
function Remove-ContentsRaw([string]$path, [int]$olderThanDays = 0) {
    # For system temp/update folders that sit inside protected areas.
    if (-not (Test-Path -LiteralPath $path)) { return }
    $cut = (Get-Date).AddDays(-$olderThanDays)
    Get-ChildItem -LiteralPath $path -Force |
        Where-Object { $olderThanDays -eq 0 -or $_.LastWriteTime -lt $cut } |
        ForEach-Object {
            if ($_.PSIsContainer) { cmd.exe /c "rd /s /q `"$($_.FullName)`"" 2>$null | Out-Null }
            else { Remove-Item -LiteralPath $_.FullName -Force }
        }
}
function Test-DockerUp {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $false }
    docker info *> $null; return ($LASTEXITCODE -eq 0)
}

function Invoke-CleanupCommand([string]$name, [string]$item) {
    switch ($name) {
        'Temp'       { Remove-ContentsRaw "$Local\Temp" 1; Remove-ContentsRaw 'C:\Windows\Temp' 1 }
        'RecycleBin' { Clear-RecycleBin -DriveLetter C -Force }
        'WinUpdate'  { Stop-Service wuauserv, bits -Force; Remove-ContentsRaw 'C:\Windows\SoftwareDistribution\Download'; Start-Service wuauserv, bits }
        'Dism'       { Dism.exe /Online /Cleanup-Image /StartComponentCleanup }
        'Hibernate'  { powercfg.exe /hibernate off }
        'Npm'        { if (Get-Command npm  -EA SilentlyContinue) { npm cache clean --force } }
        'Pnpm'       { if (Get-Command pnpm -EA SilentlyContinue) { pnpm store prune } }
        'Pip'        { if (Get-Command pip  -EA SilentlyContinue) { pip cache purge } }
        'Uv'         { if (Get-Command uv   -EA SilentlyContinue) { uv cache clean } }
        'Browsers'   {
            if (Get-Process chrome, msedge, brave) { Write-Host '   a browser is open - close it and re-run this item' -ForegroundColor DarkYellow; return }
            foreach ($r in @("$Local\Google\Chrome\User Data", "$Local\Google\Chrome SxS\User Data",
                             "$Local\Microsoft\Edge\User Data", "$Local\BraveSoftware\Brave-Browser\User Data")) {
                if (-not (Test-Path -LiteralPath $r)) { continue }
                foreach ($n in 'ShaderCache', 'GrShaderCache', 'GraphiteDawnCache') { Remove-ContentsRaw (Join-Path $r $n) }
                Get-ChildItem -LiteralPath $r -Directory -Force | ForEach-Object {
                    foreach ($n in 'Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache', 'Service Worker\CacheStorage') {
                        Remove-ContentsRaw (Join-Path $_.FullName $n)
                    }
                }
            }
        }
        'Clipchamp'  {
            Get-Process *clipchamp* | Stop-Process -Force
            $pkg = Get-AppxPackage -Name 'Clipchamp.Clipchamp'
            if ($pkg -and (Get-Command Reset-AppxPackage -EA SilentlyContinue)) { $pkg | Reset-AppxPackage }
            elseif ($clip) { Remove-ContentsRaw (Join-Path $clip.FullName 'LocalState') }
        }
        'DockerImages'  { if (Test-DockerUp) { docker container prune -f; docker image prune -a -f } else { Write-Host '   Docker not running - skipped' } }
        'DockerBuild'   { if (Test-DockerUp) { docker builder prune -a -f } else { Write-Host '   Docker not running - skipped' } }
        'DockerVolumes' { if (Test-DockerUp) { docker volume prune -a -f } else { Write-Host '   Docker not running - skipped' } }
        'CompactDisks'  {
            if (Test-DockerUp) { docker run --rm --privileged --pid=host alpine nsenter -t 1 -m -u -n -i fstrim -av }
            foreach ($d in (Get-WslDistros)) { if ($d.Name -notlike 'docker-desktop*') { wsl.exe -d $d.Name -u root fstrim -av 2>$null } }
            Get-Process 'Docker Desktop', 'com.docker.backend', 'com.docker.build' | Stop-Process -Force
            wsl.exe --shutdown
            Start-Sleep -Seconds 10
            $disks = @(Get-ChildItem -LiteralPath "$Local\Docker\wsl" -Recurse -Filter *.vhdx -File -Force | ForEach-Object FullName) +
                     @(Get-WslDistros | ForEach-Object Vhdx)
            foreach ($f in ($disks | Where-Object { $_ } | Sort-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $f)) { continue }
                Write-Host "   shrinking $f ($((Fmt (Get-Item -LiteralPath $f -Force).Length).Trim())) ..."
                $ds = Join-Path $env:TEMP 'compact_vhdx.txt'
                @("select vdisk file=`"$f`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk') | Set-Content -Path $ds -Encoding ASCII
                diskpart.exe /s $ds | Out-Null
                Remove-Item $ds -Force
                Write-Host "   now $((Fmt (Get-Item -LiteralPath $f -Force).Length).Trim())"
            }
            Write-Host '   Docker Desktop was shut down - start it again when you need it.' -ForegroundColor Yellow
        }
        default {
            if ($item -like "Remove WSL distro*") { wsl.exe --unregister $name }
        }
    }
}

$startFree = Free
foreach ($c in ($selected | Sort-Object Order)) {
    Write-Host "`n>> $($c.Item)" -ForegroundColor Cyan
    $before = Free
    try {
        switch ($c.Kind) {
            'Folder'   { Remove-PathSafe $c.Item }
            'File'     { Remove-PathSafe $c.Item }
            'Contents' { Remove-Contents $c.Item }
            'Cmd'      { Invoke-CleanupCommand $c.Arg $c.Item }
        }
    } catch { Write-Host "   error: $($_.Exception.Message)" -ForegroundColor Red }
    $freed = (Free) - $before
    if ($freed -gt 1MB) { Write-Host "   freed $((Fmt $freed).Trim())" -ForegroundColor Green } else { Write-Host '   done' -ForegroundColor DarkGray }
}

$endFree = Free
Write-Host "`n=== DONE ===" -ForegroundColor White
Write-Host "Free space: $((Fmt $startFree).Trim())  ->  $((Fmt $endFree).Trim())   (freed $((Fmt ($endFree - $startFree)).Trim()))" -ForegroundColor Green
if ($script:Skipped) { Write-Host "$($script:Skipped) items were in use and left alone." -ForegroundColor DarkGray }
if ($selected | Where-Object { $_.Arg -like 'Docker*' }) {
    if (-not ($selected | Where-Object Arg -eq 'CompactDisks')) {
        Write-Host 'Tip: Docker space is only returned to C: after "Shrink Docker + WSL disk files" - run the report again and pick it.' -ForegroundColor Yellow
    }
}
