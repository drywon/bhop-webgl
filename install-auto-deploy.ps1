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
    foreach($p in @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )){ if(Test-Path -LiteralPath $p){ return $p } }

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
        if($ahead -gt 0){
            & $git branch ('auto-backup/'+$stamp) HEAD | Out-Null
        }

        $dirty=@(& $git status --porcelain)
        if($dirty.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace(($dirty -join ''))){
            & $git stash push -u -m ('BHOP AUTO BACKUP '+$stamp) | Out-Null
        }

        & $git reset --hard origin/main | Out-Null
        if($LASTEXITCODE -ne 0){ throw 'git reset failed' }
    }
}
finally{ Pop-Location }

$root=Join-Path $env:LOCALAPPDATA 'BHOPAutoDeploy'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$bootstrapSource=Join-Path $Project 'Tools\AutoDeployBootstrap.ps1'
$bootstrapTarget=Join-Path $root 'AutoDeployBootstrap.ps1'
if(-not (Test-Path -LiteralPath $bootstrapSource)){ throw 'AutoDeployBootstrap.ps1 missing after sync.' }
Copy-Item -LiteralPath $bootstrapSource -Destination $bootstrapTarget -Force
Set-Content -LiteralPath (Join-Path $root 'ProjectPath.txt') -Value $Project -Encoding UTF8

$psExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$taskRun='"'+$psExe+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$bootstrapTarget+'"'
$taskHealth=$taskRun+' -HealthCheck'

& schtasks.exe /Delete /TN "BHOP Auto Deploy" /F *> $null
& schtasks.exe /Delete /TN "BHOP Auto Deploy Health" /F *> $null
& schtasks.exe /Create /TN "BHOP Auto Deploy" /SC ONLOGON /TR $taskRun /F | Out-Null
if($LASTEXITCODE -ne 0){ throw 'Could not create BHOP Auto Deploy logon task.' }
& schtasks.exe /Create /TN "BHOP Auto Deploy Health" /SC MINUTE /MO 1 /TR $taskHealth /F | Out-Null
if($LASTEXITCODE -ne 0){ throw 'Could not create BHOP Auto Deploy Health task.' }

$startup=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\BHOP Auto Deploy.cmd'
$startupText='@echo off'+[Environment]::NewLine+
    'start "" /min "'+$psExe+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$bootstrapTarget+'"'
Set-Content -LiteralPath $startup -Value $startupText -Encoding ASCII

Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -File "'+$bootstrapTarget+'"') -WindowStyle Hidden

Write-Host ''
Write-Host '[OK] FULL AUTO DEPLOY INSTALLED'
Write-Host ('Project: '+$Project)
Write-Host 'GitHub check: every 1 minute'
Write-Host 'Self-heal: every 1 minute'
Write-Host 'Auto-start: Windows logon + Startup fallback'
Write-Host 'Future commits require no manual git fetch/reset/start.'
