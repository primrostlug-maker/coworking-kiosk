<#
.SYNOPSIS
    Полное автономное развертывание станции коворкинга Windows 11.
    Запуск в PowerShell от имени Администратора.
#>
[CmdletBinding()]
param ()

# 0. Проверка привилегий Администратора
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен от имени Администратора!"
    exit 1
}

# 1. Чтение конфигурации или установка дефолтов
$ConfigFile = Join-Path$PSScriptRoot "config.json"
if (Test-Path $ConfigFile) {
    $Config = Get-Content -Raw -Path$ConfigFile | ConvertFrom-Json
    $GuestPassword =$Config.General.DefaultPassword
    $SharesRoot =$Config.NetworkShare.RootStoragePath
    $VeyonPorts =$Config.Veyon.Ports
} else {
    $GuestPassword = "CoworkingStationPass2026!"
    $SharesRoot = "C:\Shares"
    $VeyonPorts = @(11100, 11200, 11300, 11400)
}

$TargetUser =$env:COMPUTERNAME

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Настройка рабочей станции коворкинга: $TargetUser         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 2. Создание пользователя (Имя = Имя ПК)
Write-Host "[1/7] Создание локальной учетной записи $TargetUser..." -ForegroundColor Yellow
$user = Get-LocalUser -Name$TargetUser -ErrorAction SilentlyContinue
if (-not $user) {
    $SecPass = ConvertTo-SecureString$GuestPassword -AsPlainText -Force
    New-LocalUser -Name $TargetUser -Password$SecPass -FullName "Coworking Station ($TargetUser)" -PasswordNeverExpires $true | Out-Null
    Add-LocalGroupMember -Group "Users" -Member $TargetUser
    Write-Host "Пользователь $TargetUser создан." -ForegroundColor Green
} else {
    Write-Host "Пользователь $TargetUser уже существует." -ForegroundColor Gray
}

# 3. Настройка Auto-Logon (автоматический вход без ввода пароля)
Write-Host "[2/7] Настройка автоматического входа в систему..." -ForegroundColor Yellow
$WinlogonKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $WinlogonKey -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $WinlogonKey -Name "DefaultUserName" -Value $TargetUser
Set-ItemProperty -Path $WinlogonKey -Name "DefaultPassword" -Value $GuestPassword

# 4. Внедрение ограничений через шаблон Default User (до первого логина)
Write-Host "[3/7] Прошивка ограничений оболочки в NTUSER.DAT..." -ForegroundColor Yellow
$DefaultUserDat = "C:\Users\Default\NTUSER.DAT"
reg load "HKU\DefaultProfile" $DefaultUserDat | Out-Null

$SysPol = "Registry::HKU\DefaultProfile\Software\Microsoft\Windows\CurrentVersion\Policies\System"
$ExpPol = "Registry::HKU\DefaultProfile\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"

if (-not (Test-Path $SysPol)) { New-Item -Path$SysPol -Force | Out-Null }
Set-ItemProperty -Path $SysPol -Name "DisableTaskMgr" -Value 1 -Type DWord
Set-ItemProperty -Path $SysPol -Name "DisableChangePassword" -Value 1 -Type DWord
Set-ItemProperty -Path $SysPol -Name "DisableLockWorkstation" -Value 1 -Type DWord

if (-not (Test-Path $ExpPol)) { New-Item -Path$ExpPol -Force | Out-Null }
Set-ItemProperty -Path $ExpPol -Name "NoRun" -Value 1 -Type DWord             # Блокировка Win+R
Set-ItemProperty -Path $ExpPol -Name "NoControlPanel" -Value 1 -Type DWord    # Блокировка параметров и панели управления
Set-ItemProperty -Path $ExpPol -Name "NoFolderOptions" -Value 1 -Type DWord   # Скрытие свойств папок
Set-ItemProperty -Path $ExpPol -Name "NoDrives" -Value 4 -Type DWord          # Скрытие системного диска C: (бит 4 = C:)

[GC]::Collect()
[GC]::WaitForPendingFinalizers()
reg unload "HKU\DefaultProfile" | Out-Null

# 5. Сетевая папка (SMB) и ярлыки
Write-Host "[4/7] Создание и расшаривание папки $SharesRoot\$TargetUser..." -ForegroundColor Yellow
$UserShareDir = Join-Path $SharesRoot$TargetUser
if (-not (Test-Path $UserShareDir)) {
    New-Item -ItemType Directory -Path $UserShareDir -Force | Out-Null
}

$Acl = Get-Acl$UserShareDir
$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($TargetUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.SetAccessRule($AccessRule)
Set-Acl -Path $UserShareDir -AclObject$Acl

if (-not (Get-SmbShare -Name $TargetUser -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $TargetUser -Path $UserShareDir -FullAccess$TargetUser, "Administrators" -ReadAccess "Everyone" | Out-Null
}

# Ярлык на сетевую папку в Public Desktop (виден сразу любому пользователю)
$WshShell = New-Object -ComObject WScript.Shell
$PublicDesktop = "C:\Users\Public\Desktop"
$Shortcut =$WshShell.CreateShortcut("$PublicDesktop\Сетевая папка ($TargetUser).lnk")
$Shortcut.TargetPath = "\\$env:COMPUTERNAME\$TargetUser"
$Shortcut.IconLocation = "shell32.dll,275"
$Shortcut.Save()

# 6. Блокировка запуска исполняемых файлов с USB и отключение автозапуска
Write-Host "[5/7] Применение защитных политик USB..." -ForegroundColor Yellow
$UsbPolicyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}"
if (-not (Test-Path $UsbPolicyKey)) { New-Item -Path$UsbPolicyKey -Force | Out-Null }
Set-ItemProperty -Path $UsbPolicyKey -Name "Deny_Execute" -Value 1 -Type DWord

$ExplorerPolicyKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (-not (Test-Path $ExplorerPolicyKey)) { New-Item -Path$ExplorerPolicyKey -Force | Out-Null }
Set-ItemProperty -Path $ExplorerPolicyKey -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord

# 7. Конфигурация Veyon
Write-Host "[6/7] Настройка службы и сетевых портов Veyon..." -ForegroundColor Yellow
Remove-NetFirewallRule -DisplayName "Veyon Coworking Inbound" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Veyon Coworking Inbound" -Direction Inbound -LocalPort $VeyonPorts -Protocol TCP -Action Allow | Out-Null

$VeyonCli = "C:\Program Files\Veyon\veyon-cli.exe"
if (Test-Path $VeyonCli) {
    $VeyonConfigFile = Join-Path$PSScriptRoot "configs\veyon-config.json"
    if (Test-Path $VeyonConfigFile) {
        Write-Host "Импорт настроек Veyon..." -ForegroundColor Cyan
        & $VeyonCli config import$VeyonConfigFile
    }
    & $VeyonCli service restart
}

$VeyonService = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
if ($VeyonService) {
    Set-Service -Name "VeyonService
