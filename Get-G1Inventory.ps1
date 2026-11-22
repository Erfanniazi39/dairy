<#
.SYNOPSIS
  G1 inventory collector for ONE Windows machine (PC or server). READ-ONLY: changes nothing.

.DESCRIPTION
  Collects hardware, OS, security posture, local admins, network, installed software and
  (on servers) roles + listening ports. Writes:
    <OutDir>\<COMPUTER>-summary.csv    one row, merge all of these later
    <OutDir>\<COMPUTER>-software.csv   installed programs
    <OutDir>\<COMPUTER>-listening.csv  servers only: listening TCP ports + process
  Also returns the summary object, so it works with Invoke-Command.

  Run as local Administrator (needed for BitLocker/TPM). PowerShell 5.1+ (Windows 10 / Server 2016+;
  works on 2012 R2 with a few blank fields).

.EXAMPLE
  # Local, results to a USB stick or share
  powershell -ExecutionPolicy Bypass -File .\Get-G1Inventory.ps1 -OutDir E:\G1

.EXAMPLE
  # Remote, domain servers with WinRM (results come back to your machine)
  $servers = Get-Content .\servers.txt
  Invoke-Command -ComputerName $servers -FilePath .\Get-G1Inventory.ps1 -ArgumentList 'C:\Windows\Temp\G1' |
    Select-Object * -ExcludeProperty PSComputerName,RunspaceId,PSShowComputerName |
    Export-Csv .\servers-summary.csv -NoTypeInformation -Encoding UTF8
#>
param(
    [string]$OutDir = "$env:PUBLIC\G1-Inventory"
)

$ErrorActionPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$name = $env:COMPUTERNAME

$cs   = Get-CimInstance Win32_ComputerSystem
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$reg  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$isServer = ($os.ProductType -ne 1)   # 1 = workstation, 2 = DC, 3 = member server

# Disks and volumes
$disks = (Get-CimInstance Win32_DiskDrive | ForEach-Object {
    "{0} {1}GB {2}" -f $_.Model.Trim(), [math]::Round($_.Size/1GB), $_.Status }) -join ' | '
$vols = (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    "{0} {1}GB free of {2}GB" -f $_.DeviceID, [math]::Round($_.FreeSpace/1GB), [math]::Round($_.Size/1GB) }) -join ' | '
$mediaType = (Get-PhysicalDisk | ForEach-Object { "$($_.FriendlyName):$($_.MediaType):$($_.HealthStatus)" }) -join ' | '

# Network
$nics = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True"
$ips  = ($nics | ForEach-Object { $_.IPAddress | Where-Object { $_ -match '^\d+\.' } }) -join ', '
$macs = ($nics.MACAddress) -join ', '
$dhcp = ($nics | ForEach-Object { $_.DHCPEnabled }) -join ', '
$dns  = ($nics | ForEach-Object { $_.DNSServerSearchOrder }) -join ', '
$gw   = ($nics | ForEach-Object { $_.DefaultIPGateway }) -join ', '

# Local Administrators (by SID, so it works on Persian/other-language Windows)
$adminGroup = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate(
                [System.Security.Principal.NTAccount]).Value.Split('\')[-1]
$admins = @()
try {
    $grp = [ADSI]"WinNT://./$adminGroup,group"
    $admins = $grp.Invoke('Members') | ForEach-Object {
        $p = $_.GetType().InvokeMember('ADsPath','GetProperty',$null,$_,$null)
        $p -replace '^WinNT://','' -replace '/','\'
    }
} catch {}
$localUsers = (Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" |
    ForEach-Object { "{0}{1}" -f $_.Name, $(if ($_.Disabled) {'(disabled)'} else {''}) }) -join ', '

# Security posture
$bitlocker = (Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName Win32_EncryptableVolume |
    ForEach-Object { "{0}:{1}" -f $_.DriveLetter, @('Off','On','Unknown')[[int]$_.ProtectionStatus] }) -join ', '
$tpm = Get-CimInstance -Namespace 'root\cimv2\security\microsofttpm' -ClassName Win32_Tpm
$tpmInfo = if ($tpm) { "Present; spec $($tpm.SpecVersion.Split(',')[0]); enabled=$($tpm.IsEnabled_InitialValue)" } else { 'None/unknown' }
$av = if (-not $isServer) {
    (Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct).displayName -join ', '
} else {
    $d = Get-MpComputerStatus
    if ($d) { "Defender: RTP=$($d.RealTimeProtectionEnabled) sigAge=$($d.AntivirusSignatureAge)d" } else { 'check manually' }
}
$lastPatch = Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
$rdp = (Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections -eq 0
$smb1 = $null
try { $smb1 = (Get-SmbServerConfiguration).EnableSMB1Protocol } catch {}
$fw = (Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$($_.Enabled)" }) -join ', '

# Support status flag (verify dates against Microsoft lifecycle pages)
$caption = $os.Caption
$build = [int]$os.BuildNumber
$flag = switch -Regex ($caption) {
    'Windows 10'                   { 'UNSUPPORTED since 2025-10-14 (unless ESU)'; break }
    'Windows (7|8)'                { 'UNSUPPORTED'; break }
    'Server 2008|Server 2012'      { 'UNSUPPORTED'; break }
    'Server 2016'                  { 'Extended support ends 2027-01-12 - plan now'; break }
    'Windows 11'                   { if ($build -lt 26100) { 'Check feature update (23H2 or older)' } else { 'OK' }; break }
    default                        { 'Check lifecycle' }
}

$summary = [pscustomobject]@{
    ComputerName     = $name
    Domain           = $cs.Domain
    PartOfDomain     = $cs.PartOfDomain
    Role             = @('','Workstation','DomainController','MemberServer')[[int]$os.ProductType]
    Manufacturer     = $cs.Manufacturer
    Model            = $cs.Model
    Serial           = $bios.SerialNumber
    BIOSVersion      = $bios.SMBIOSBIOSVersion
    BIOSDate         = $bios.ReleaseDate
    IsVirtual        = ($cs.Model -match 'Virtual|VMware|KVM|QEMU|HVM|Proxmox')
    CPU              = $cpu.Name.Trim()
    Cores            = $cpu.NumberOfCores
    RAM_GB           = [math]::Round($cs.TotalPhysicalMemory/1GB)
    Disks            = $disks
    DiskMedia        = $mediaType
    Volumes          = $vols
    OS               = $caption
    OSDisplayVersion = $reg.DisplayVersion
    OSBuild          = "$($os.BuildNumber).$($reg.UBR)"
    SupportFlag      = $flag
    OSInstallDate    = $os.InstallDate
    LastBoot         = $os.LastBootUpTime
    LastHotfix       = "$($lastPatch.HotFixID) $($lastPatch.InstalledOn)"
    IPs              = $ips
    MACs             = $macs
    DHCP             = $dhcp
    DNSServers       = $dns
    Gateway          = $gw
    LocalAdmins      = ($admins -join '; ')
    LocalUsers       = $localUsers
    LoggedOnUser     = $cs.UserName
    BitLocker        = $bitlocker
    TPM              = $tpmInfo
    Antivirus        = $av
    RDPEnabled       = $rdp
    SMB1Enabled      = $smb1
    Firewall         = $fw
    CollectedAt      = (Get-Date -Format 's')
}

$summary | Export-Csv "$OutDir\$name-summary.csv" -NoTypeInformation -Encoding UTF8

# Installed software
$paths = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
         'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
Get-ItemProperty $paths | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
    Select-Object @{n='ComputerName';e={$name}}, DisplayName, DisplayVersion, Publisher, InstallDate |
    Sort-Object DisplayName -Unique |
    Export-Csv "$OutDir\$name-software.csv" -NoTypeInformation -Encoding UTF8

# Servers: roles and listening ports (this is how undocumented apps get found)
if ($isServer) {
    try {
        (Get-WindowsFeature | Where-Object Installed | Where-Object FeatureType -eq 'Role').Name -join ', ' |
            Out-File "$OutDir\$name-roles.txt" -Encoding UTF8
    } catch {}
    Get-NetTCPConnection -State Listen | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess
        [pscustomobject]@{ ComputerName=$name; LocalAddress=$_.LocalAddress; Port=$_.LocalPort
                           Process=$p.ProcessName; Path=$p.Path }
    } | Sort-Object Port -Unique |
      Export-Csv "$OutDir\$name-listening.csv" -NoTypeInformation -Encoding UTF8
}

$summary
