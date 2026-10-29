<#
.SYNOPSIS
    Автоматизированная настройка ПК коворкинга в режиме защищенной станции.
#>
[CmdletBinding()]
param ()

# Проверка административных прав
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "Скрипт должен быть запущен в PowerShell от имени Администратора!"
    exit 1
}

$ConfigFile = Join-Path $PSScriptRoot "config.json"
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Файл конфигурации config.json не найден!"
    exit 1
}
$Config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json

# Имя ПК = Имя пользователя = Имя сетевой папки
$TargetUser = $env:COMPUTERNAME

Write-Host "=================================================" -ForegroundColor Cyan
Write-Host " Старт конфигурации рабочей станции: $TargetUser" -ForegroundColor Cyan
Write-Host "=================================================" -ForegroundColor Cyan

# 1. Создание локальной учетной записи
$user = Get-LocalUser -Name $TargetUser -ErrorAction SilentlyContinue
if (-not $user) {
    Write-Host "[1/6] Создание учетной записи $TargetUser..." -ForegroundColor Yellow
    $SecPass = ConvertTo-SecureString $Config.General.DefaultPassword -AsPlainText -Force
    New-LocalUser -Name $TargetUser -Password $SecPass -FullName "Coworking Guest" -PasswordNeverExpires $true | Out-Null
    Add-LocalGroupMember -Group "Users" -Member $TargetUser
} else {
    Write-Host "[1/6] Пользователь $TargetUser уже существует." -ForegroundColor Green
}

# 2. Создание и расшаривание сетевой папки
Write-Host "[2/6] Конфигурация SMB-хранилища..." -ForegroundColor Yellow
$SharePath = Join-Path $Config.NetworkShare.RootStoragePath $TargetUser
if (-not (Test-Path $SharePath)) {
    New-Item -ItemType Directory -Path $SharePath -Force | Out-Null
}

$Acl = Get-Acl $SharePath
$Rule = New-Object System.Security.AccessControl.FileSystemAccessRule($TargetUser, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$Acl.SetAccessRule($Rule)
Set-Acl -Path $SharePath -AclObject $Acl

if (-not (Get-SmbShare -Name $TargetUser -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name $TargetUser -Path $SharePath -FullAccess $TargetUser, "Administrators" -ReadAccess "Everyone" | Out-Null
}

# Создание ярлыка в профиле пользователя и в Public Desktop
$ShortcutTarget = "\\$env:COMPUTERNAME\$TargetUser"
$WshShell = New-Object -ComObject WScript.Shell
$DesktopDirs = @(
    "C:\Users\$TargetUser\Desktop",
    "C:\Users\Public\Desktop"
)

foreach ($dir in $DesktopDirs) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Shortcut = $WshShell.CreateShortcut("$dir\Сетевая папка ($TargetUser).lnk")
    $Shortcut.TargetPath = $ShortcutTarget
    $Shortcut.IconLocation = "shell32.dll,275"
    $Shortcut.Save()
}

# 3. Блокировка запуска исполняемых файлов с флешек и отключение автозапуска
Write-Host "[3/6] Настройка защитных политик USB..." -ForegroundColor Yellow
$UsbPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}"
if (-not (Test-Path $UsbPolicy)) { New-Item -Path $UsbPolicy -Force | Out-Null }
Set-ItemProperty -Path $UsbPolicy -Name "Deny_Execute" -Value 1 -Type DWord

$AutoRun = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
if (-not (Test-Path $AutoRun)) { New-Item -Path $AutoRun -Force | Out-Null }
Set-ItemProperty -Path $AutoRun -Name "NoDriveTypeAutoRun" -Value 0xFF -Type DWord

# 4. Настройка брандмауэра и службы Veyon
Write-Host "[4/6] Проверка Veyon и открытие сетевых портов..." -ForegroundColor Yellow
$PortsList = $Config.Veyon.Ports -join ","
Remove-NetFirewallRule -DisplayName "Veyon Inbound Coworking" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Veyon Inbound Coworking" -Direction Inbound -LocalPort $Config.Veyon.Ports -Protocol TCP -Action Allow | Out-Null

$veyonSvc = Get-Service -Name $Config.Veyon.ServiceName -ErrorAction SilentlyContinue
if ($veyonSvc) {
    Set-Service -Name $Config.Veyon.ServiceName -StartupType Automatic
    if ($veyonSvc.Status -ne "Running") { Start-Service -Name $Config.Veyon.ServiceName -ErrorAction SilentlyContinue }
}

# 5. Применение политик белого списка (AppLocker)
Write-Host "[5/6] Инициализация AppLocker..." -ForegroundColor Yellow
Set-Service -Name "AppIDSvc" -StartupType Automatic
Start-Service -Name "AppIDSvc" -ErrorAction SilentlyContinue

$PolicyFile = Join-Path $PSScriptRoot "configs\AppLockerPolicy.xml"
if (Test-Path $PolicyFile) {
    Set-AppLockerPolicy -XmlPolicy $PolicyFile -ErrorAction SilentlyContinue
}

# 6. Применение ограничений проводника и системы
Write-Host "[6/6] Изоляция системных апплетов профиля..." -ForegroundColor Yellow
& "$PSScriptRoot\Set-UserRestrictions.ps1" -TargetUsername $TargetUser -ErrorAction SilentlyContinue

Write-Host "=================================================" -ForegroundColor Green
Write-Host " Станция $TargetUser полностью подготовлена!    " -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
