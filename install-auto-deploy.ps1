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

$root=Join-Path $env:LOCALAPPDATA 'BHOPAutoDeploy'
New-Item -ItemType Directory -Path $root -Force | Out-Null
$bootstrapSource=Join-Path $Project 'Tools\AutoDeployBootstrap.ps1'
$bootstrapTarget=Join-Path $root 'AutoDeployBootstrap.ps1'
$supervisorTarget=Join-Path $root 'AutoDeploySupervisor.ps1'
$projectConfig=Join-Path $root 'ProjectPath.txt'

if(-not (Test-Path -LiteralPath $bootstrapSource)){ throw 'AutoDeployBootstrap.ps1 missing after sync.' }
Copy-Item -LiteralPath $bootstrapSource -Destination $bootstrapTarget -Force
Set-Content -LiteralPath $projectConfig -Value $Project -Encoding UTF8

$supervisor=@'
$ErrorActionPreference='SilentlyContinue'
$root=Split-Path -Parent $MyInvocation.MyCommand.Path
$bootstrap=Join-Path $root 'AutoDeployBootstrap.ps1'
$log=Join-Path $root 'SUPERVISOR.log'

$created=$false
$mutex=New-Object System.Threading.Mutex($true,'Local\BHOPAutoDeploySupervisor',[ref]$created)
if(-not $created){ exit 0 }

function Log([string]$m){
    Add-Content -LiteralPath $log -Value ('['+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+'] '+$m) -Encoding UTF8
}

try{
    Log 'Supervisor started.'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrap -HealthCheck
    while($true){
        Start-Sleep -Seconds 60
        if(Test-Path -LiteralPath $bootstrap){
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrap -HealthCheck
        }
    }
}
catch{
    Log ('Supervisor loop error: '+$_.Exception.Message)
}
finally{
    try{$mutex.ReleaseMutex()}catch{}
    $mutex.Dispose()
}
'@
Set-Content -LiteralPath $supervisorTarget -Value $supervisor -Encoding UTF8

$psExe="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$runCommand='"'+$psExe+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$supervisorTarget+'"'

# No-admin persistence: current-user Run key.
$runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -Path $runKey -Name 'BHOPAutoDeploy' -Value $runCommand -Force

# Second no-admin fallback: Startup folder.
$startup=Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\BHOP Auto Deploy.cmd'
$startupText='@echo off'+[Environment]::NewLine+
    'start "" /min "'+$psExe+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$supervisorTarget+'"'
Set-Content -LiteralPath $startup -Value $startupText -Encoding ASCII

# Task Scheduler is optional now. Failure is ignored.
try{
    $taskRun='"'+$psExe+'" -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$supervisorTarget+'"'
    & schtasks.exe /Delete /TN "BHOP Auto Deploy" /F *> $null
    & schtasks.exe /Create /TN "BHOP Auto Deploy" /SC ONLOGON /TR $taskRun /F *> $null
}catch{}

# Stop old supervisors so the new version becomes authoritative.
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf('AutoDeploySupervisor.ps1',[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.ProcessId -ne $PID
    } |
    ForEach-Object { try{ Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }catch{} }

Start-Sleep -Seconds 1

# Start the fixed bootstrap once in the foreground so installation cannot claim
# success unless the watcher actually starts.
& $psExe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $bootstrapTarget
if($LASTEXITCODE -ne 0){
    $bootLog=Join-Path $Project 'AutoDeployLogs\AUTO_DEPLOY_BOOTSTRAP.log'
    if(Test-Path -LiteralPath $bootLog){
        Write-Host ''
        Write-Host '--- bootstrap log tail ---'
        Get-Content -LiteralPath $bootLog -Tail 25
    }
    throw ('Bootstrap failed with exit code '+$LASTEXITCODE)
}

Start-Sleep -Seconds 3
$watcher=Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and
        $_.CommandLine.IndexOf('AUTO_DEPLOY.ps1',[System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
        $_.CommandLine.IndexOf($Project,[System.StringComparison]::OrdinalIgnoreCase) -ge 0
    } |
    Select-Object -First 1

if(-not $watcher){
    $bootLog=Join-Path $Project 'AutoDeployLogs\AUTO_DEPLOY_BOOTSTRAP.log'
    if(Test-Path -LiteralPath $bootLog){
        Write-Host ''
        Write-Host '--- bootstrap log tail ---'
        Get-Content -LiteralPath $bootLog -Tail 25
    }
    throw 'AUTO_DEPLOY watcher did not start.'
}

Start-Process -FilePath $psExe -ArgumentList ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$supervisorTarget+'"') -WindowStyle Hidden
Start-Sleep -Seconds 2

$head=(& $git -C $Project rev-parse --short HEAD).Trim()

Write-Host ''
Write-Host '[OK] BHOP FULL AUTO DEPLOY V3 INSTALLED'
Write-Host ('Project: '+$Project)
Write-Host ('Source HEAD: '+$head)
Write-Host ('Watcher PID: '+$watcher.ProcessId+' RUNNING')
Write-Host 'Supervisor: RUNNING'
Write-Host 'GitHub watcher: self-healing every 60 sec'
Write-Host 'Auto-start: HKCU Run + Startup fallback'
Write-Host 'Admin rights: NOT REQUIRED'
Write-Host 'Future commits: no manual fetch/reset/start required.'
Write-Host ('Log: '+(Join-Path $root 'SUPERVISOR.log'))
