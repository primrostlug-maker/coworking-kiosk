<#
.SYNOPSIS
    Быстрый сброс временных данных и кэша сессии пользователя.
#>
[CmdletBinding()]
param (
    [string]$TargetUser = $env:COMPUTERNAME
)

$ConfigFile = Join-Path $PSScriptRoot "config.json"
if (Test-Path $ConfigFile) {
    $Config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
    $RelativePaths = $Config.CleanupPaths
} else {
    $RelativePaths = @(
        "AppData\Local\Temp\*",
        "Downloads\*",
        "AppData\Local\Google\Chrome\User Data\Default\Cache\*",
        "AppData\Local\Microsoft\Edge\User Data\Default\Cache\*"
    )
}

Write-Host "Очистка пользовательских данных для $TargetUser..." -ForegroundColor Yellow

$UserBase = "C:\Users\$TargetUser"
if (Test-Path $UserBase) {
    foreach ($rel in $RelativePaths) {
        $fullPath = Join-Path $UserBase $rel
        if (Test-Path $fullPath) {
            Remove-Item -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Host "Сессия $TargetUser очищена." -ForegroundColor Green
} else {
    Write-Warning "Каталог пользователя $UserBase не найден."
}
