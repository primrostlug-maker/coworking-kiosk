<#
.SYNOPSIS
    Блокировка системных апплетов, горячих клавиш и диспетчера задач для конкретного пользователя.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$TargetUsername
)

try {
    $UserSID = (New-Object System.Security.Principal.NTAccount($TargetUsername)).Translate([System.Security.Principal.SecurityIdentifier]).Value
} catch {
    Write-Warning "Не удалось получить SID для $TargetUsername. Ограничения будут применены при первом входе."
    exit 0
}

$RegPath = "Registry::HKEY_USERS\$UserSID\Software\Microsoft\Windows\CurrentVersion\Policies"
Write-Host "Применение ограничений интерфейса для SID: $UserSID" -ForegroundColor Cyan

# Блокировка Диспетчера задач, смены пароля и экрана блокировки
$SystemKey = "$RegPath\System"
if (-not (Test-Path $SystemKey)) { New-Item -Path $SystemKey -Force | Out-Null }
Set-ItemProperty -Path $SystemKey -Name "DisableTaskMgr" -Value 1 -Type DWord
Set-ItemProperty -Path $SystemKey -Name "DisableLockWorkstation" -Value 1 -Type DWord
Set-ItemProperty -Path $SystemKey -Name "DisableChangePassword" -Value 1 -Type DWord

# Ограничения Проводника (Explorer)
$ExplorerKey = "$RegPath\Explorer"
if (-not (Test-Path $ExplorerKey)) { New-Item -Path $ExplorerKey -Force | Out-Null }
Set-ItemProperty -Path $ExplorerKey -Name "NoRun" -Value 1 -Type DWord             # Блокировка Win+R
Set-ItemProperty -Path $ExplorerKey -Name "NoControlPanel" -Value 1 -Type DWord    # Запрет Панели управления и Параметров
Set-ItemProperty -Path $ExplorerKey -Name "NoFolderOptions" -Value 1 -Type DWord   # Скрытие параметров папок
Set-ItemProperty -Path $ExplorerKey -Name "NoDrives" -Value 4 -Type DWord          # Скрытие диска C: в «Этот компьютер» (бит 4 = C:)

Write-Host "Системные ограничения пользователя применены." -ForegroundColor Green
