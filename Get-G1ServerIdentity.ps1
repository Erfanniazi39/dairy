<#
.SYNOPSIS
  G1 - Server identity (assessment section 2.5). READ-ONLY: changes nothing.

.DESCRIPTION
  Collects the server's basic facts: name, brand, model, serial, CPU, RAM (including
  installed sticks and free slots), Windows version, activation, support status and
  age clues. Saves them in a "G1\Server" folder next to this script:

    <script folder>\G1\Server\<SERVERNAME>-identity.txt   readable report + fields to fill by hand
    <script folder>\G1\Server\<SERVERNAME>-identity.csv   one row, for the inventory spreadsheet

  Run in an Administrator PowerShell:
    powershell -ExecutionPolicy Bypass -File E:\Get-G1ServerIdentity.ps1

  Optional: choose another output folder
    powershell -ExecutionPolicy Bypass -File E:\Get-G1ServerIdentity.ps1 -OutDir D:\Somewhere
#>
param(
    [string]$OutDir = (Join-Path $PSScriptRoot 'G1\Server')
)

$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$os   = Get-CimInstance Win32_OperatingSystem
$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$cpu  = @(Get-CimInstance Win32_Processor)
$mem  = @(Get-CimInstance Win32_PhysicalMemory)
$slots = (Get-CimInstance Win32_PhysicalMemoryArray | Measure-Object MemoryDevices -Sum).Sum
$lic  = Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND Name LIKE 'Windows%'" |
        Select-Object -First 1
$name = $os.CSName

# Windows edition (last word of the caption) and support status
$caption = $os.Caption
$support = switch -Regex ($caption) {
    '2008|2012'  { 'UNSUPPORTED - high risk'; break }
    '2016'       { 'Support ends 2027-01-12 - plan replacement'; break }
    '2019'       { 'Supported until 2029-01-09'; break }
    '2022'       { 'Supported until 2031-10-14'; break }
    '2025'       { 'Supported'; break }
    default      { 'Check Microsoft lifecycle page' }
}

$licStatus = switch ([int]$lic.LicenseStatus) {
    1 { 'Yes (Licensed)' } 0 { 'NO (Unlicensed)' } 2 { 'NO (Grace period)' } 3 { 'NO (Grace period)' }
    5 { 'NO (Notification mode)' } default { 'Unknown - run: slmgr /dli' }
}

# Disk power-on hours: an age clue if the disks are original
$diskHours = Get-PhysicalDisk | Get-StorageReliabilityCounter | Where-Object PowerOnHours |
             Measure-Object PowerOnHours -Maximum
$diskYears = if ($diskHours.Maximum) { [math]::Round($diskHours.Maximum / 8760, 1) } else { 'n/a (hidden by RAID controller)' }

$ramSticks = $mem | ForEach-Object {
    $slot = ("$($_.BankLabel) $($_.DeviceLocator)").Trim()
    "{0,-24} {1,4} GB  {2,5} MHz  {3}  {4}" -f $slot, [math]::Round($_.Capacity / 1GB), $_.Speed,
        ("$($_.Manufacturer)").Trim(), ("$($_.PartNumber)").Trim()
}

$info = [ordered]@{
    'Server name'          = $name
    'Brand'                = $cs.Manufacturer
    'Model'                = $cs.Model
    'Serial number'        = $bios.SerialNumber
    'CPU'                  = $cpu[0].Name.Trim()
    'CPU count'            = $cpu.Count
    'Cores (total)'        = ($cpu | Measure-Object NumberOfCores -Sum).Sum
    'Threads (total)'      = ($cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
    'RAM (GB)'             = [math]::Round($cs.TotalPhysicalMemory / 1GB)
    'RAM sticks installed' = $mem.Count
    'RAM slots total'      = $slots
    'RAM slots free'       = if ($slots) { $slots - $mem.Count } else { 'unknown' }
    'Windows version'      = $caption
    'Build'                = "$($os.BuildNumber)"
    'Activated?'           = $licStatus
    'Support status'       = $support
    'Domain / workgroup'   = $cs.Domain
    'Part of domain'       = $cs.PartOfDomain
    'Windows installed'    = $os.InstallDate.ToString('yyyy-MM-dd')
    'BIOS version'         = $bios.SMBIOSBIOSVersion
    'BIOS date'            = $bios.ReleaseDate.ToString('yyyy-MM-dd')
    'Disk power-on years'  = $diskYears
    'Last boot'            = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
    'Collected at'         = (Get-Date -Format 'yyyy-MM-dd HH:mm')
}

# ---- Text report ----
$txt = Join-Path $OutDir "$name-identity.txt"
$lines = @()
$lines += "G1 - SERVER IDENTITY : $name"
$lines += ('=' * 60)
foreach ($k in $info.Keys) { $lines += ("{0,-22}: {1}" -f $k, $info[$k]) }
$lines += ''
$lines += 'RAM sticks (slot, size, speed, maker, part number):'
$lines += ($ramSticks | ForEach-Object { "  $_" })
$lines += ''
$lines += ('-' * 60)
$lines += 'FILL IN BY HAND (no command can find these):'
$lines += '  Purchase date / invoice  : '
$lines += '  Seller / importer        : '
$lines += '  Local warranty until     : '
$lines += '  Vendor warranty          : '
$lines += '  Estimated age            : '
$lines += '  Serial matches sticker?  : '
$lines += '  Notes                    : '
$lines | Out-File $txt -Encoding UTF8

# ---- CSV (one row) ----
$csv = Join-Path $OutDir "$name-identity.csv"
[pscustomobject]$info | Export-Csv $csv -NoTypeInformation -Encoding UTF8

# ---- Show on screen ----
$lines | Select-Object -First ($info.Count + 3 + $mem.Count) | ForEach-Object { Write-Host $_ }
Write-Host ''
Write-Host "Saved:" -ForegroundColor Green
Write-Host "  $txt"
Write-Host "  $csv"
