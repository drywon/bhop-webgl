$ErrorActionPreference='Stop'

$projectCandidates=@(
    'C:\Users\User\Documents\BHOP_Yandex',
    (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'BHOP_Yandex')
)
$Project=$projectCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_ '.git') } | Select-Object -First 1
if(-not $Project){ throw 'BHOP_Yandex repository not found.' }

function Find-Git {
    $g=Get-Command git.exe -ErrorAction SilentlyContinue
    if($g){ return $g.Source }
    foreach($p in @('C:\Program Files\Git\cmd\git.exe','C:\Program Files\Git\bin\git.exe')){
        if(Test-Path -LiteralPath $p){ return $p }
    }
    $desktop=Join-Path $env:LOCALAPPDATA 'GitHubDesktop'
    if(Test-Path -LiteralPath $desktop){
        $candidate=Get-ChildItem -LiteralPath $desktop -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending |
            ForEach-Object { Join-Path $_.FullName 'resources\app\git\cmd\git.exe' } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1
        if($candidate){ return $candidate }
    }
    throw 'git.exe not found.'
}

$git=Find-Git
Push-Location $Project
try{
    & $git fetch origin main --quiet
    if($LASTEXITCODE -ne 0){ throw 'git fetch failed' }

    $local=(& $git rev-parse HEAD).Trim()
    $remote=(& $git rev-parse origin/main).Trim()

    if($local -ne $remote){
        $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
        $ahead=[int]((& $git rev-list --count origin/main..HEAD).Trim())
        if($ahead -gt 0){ & $git branch ('auto-backup/'+$stamp) HEAD | Out-Null }

        $dirty=@(& $git status --porcelain)
        if($dirty.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(($dirty -join ''))){
            & $git stash push -u -m ('BHOP AUTO BACKUP '+$stamp) | Out-Null
        }

        & $git reset --hard origin/main | Out-Null
        if($LASTEXITCODE -ne 0){ throw 'git reset failed' }
    }
}
finally{ Pop-Location }

$installer=Join-Path $Project 'Tools\InstallAutoDeploy.ps1'
if(-not (Test-Path -LiteralPath $installer)){ throw 'Quiet installer missing after sync.' }

& powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installer
if($LASTEXITCODE -ne 0){ throw ('Quiet installer failed with exit code '+$LASTEXITCODE) }

$head=(& $git -C $Project rev-parse --short HEAD).Trim()
Write-Host ''
Write-Host '[OK] BHOP QUIET AUTO DEPLOY INSTALLED'
Write-Host ('Project: '+$Project)
Write-Host ('Source HEAD: '+$head)
Write-Host 'No supervisor. No periodic health-check PowerShell windows.'
Write-Host 'Future commits are handled by one hidden watcher.'
