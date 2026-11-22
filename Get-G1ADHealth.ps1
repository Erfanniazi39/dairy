<#
.SYNOPSIS
  G1 Active Directory + core services snapshot. READ-ONLY: changes nothing.

.DESCRIPTION
  Run ON a domain controller, in an elevated PowerShell, as a domain admin.
  Collects: dcdiag, replication, FSMO, functional levels, privileged group members,
  all users and computers (with stale/OS flags), password policy, krbtgt age, trusts,
  GPOs, DNS forwarders/zones, DHCP scopes, time source, certificate expiry.
  Group lookups use SIDs, so it works on non-English Windows.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Get-G1ADHealth.ps1 -OutDir C:\G1\AD
#>
param([string]$OutDir = "C:\G1\AD-$(Get-Date -Format yyyyMMdd)")

$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Import-Module ActiveDirectory
$stale = (Get-Date).AddDays(-90)
function Save {
    param([Parameter(Position=0, ValueFromPipeline=$true)]$InputObject, [Parameter(Position=1)][string]$file)
    begin   { $all = @() }
    process { $all += $InputObject }
    end     { $all | Export-Csv (Join-Path $OutDir $file) -NoTypeInformation -Encoding UTF8 }
}

Write-Host "1/9 dcdiag + replication (takes a few minutes)..."
dcdiag /e /v              > "$OutDir\dcdiag-verbose.txt" 2>&1
dcdiag /e /q              > "$OutDir\dcdiag-errors-only.txt" 2>&1   # empty file = good
dcdiag /test:dns /e /v    > "$OutDir\dcdiag-dns.txt" 2>&1
repadmin /replsummary     > "$OutDir\repadmin-replsummary.txt" 2>&1
repadmin /showrepl * /csv > "$OutDir\repadmin-showrepl.csv" 2>&1
netdom query fsmo         > "$OutDir\fsmo.txt" 2>&1

Write-Host "2/9 Domain and forest..."
$dom = Get-ADDomain; $for = Get-ADForest
[pscustomobject]@{
    Domain = $dom.DNSRoot; NetBIOS = $dom.NetBIOSName
    DomainMode = $dom.DomainMode; ForestMode = $for.ForestMode
    DCs = ((Get-ADDomainController -Filter *) | ForEach-Object { "$($_.HostName) [$($_.OperatingSystem)] GC=$($_.IsGlobalCatalog)" }) -join '; '
    PDC = $dom.PDCEmulator; RID = $dom.RIDMaster; Infra = $dom.InfrastructureMaster
    Schema = $for.SchemaMaster; Naming = $for.DomainNamingMaster
    Sites = ($for.Sites -join ', ')
    RecycleBin = [bool](Get-ADOptionalFeature -Filter "Name -like 'Recycle Bin Feature'").EnabledScopes
    KrbtgtPwdLastSet = (Get-ADUser krbtgt -Properties PasswordLastSet).PasswordLastSet
} | Save -file 'domain-summary.csv'
Get-ADTrust -Filter * | Select-Object Name, Direction, TrustType, ForestTransitive | Save -file 'trusts.csv'

Write-Host "3/9 Password policy..."
Get-ADDefaultDomainPasswordPolicy | Select-Object * | Save -file 'password-policy-default.csv'
Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object * | Save -file 'password-policy-finegrained.csv'

Write-Host "4/9 Privileged groups (by SID)..."
$sid     = $dom.DomainSID.Value
$rootSid = (Get-ADDomain $for.RootDomain).DomainSID.Value
$priv = [ordered]@{
    'Domain Admins'="$sid-512"; 'Enterprise Admins'="$rootSid-519"; 'Schema Admins'="$rootSid-518"
    'Group Policy Creator Owners'="$sid-520"
    'Administrators'='S-1-5-32-544'; 'Account Operators'='S-1-5-32-548'; 'Server Operators'='S-1-5-32-549'
    'Print Operators'='S-1-5-32-550'; 'Backup Operators'='S-1-5-32-551'; 'DnsAdmins'=$null
}
$rows = foreach ($k in $priv.Keys) {
    $g = if ($priv[$k]) { Get-ADGroup -Identity $priv[$k] } else { Get-ADGroup -Filter "Name -eq '$k'" }
    if (-not $g) { continue }
    Get-ADGroupMember $g -Recursive | ForEach-Object {
        $u = if ($_.objectClass -eq 'user') { Get-ADUser $_ -Properties Enabled, LastLogonDate, PasswordLastSet, PasswordNeverExpires } else { $_ }
        [pscustomobject]@{ Group=$g.Name; Member=$_.SamAccountName; Type=$_.objectClass; Enabled=$u.Enabled
                           LastLogon=$u.LastLogonDate; PwdLastSet=$u.PasswordLastSet; PwdNeverExpires=$u.PasswordNeverExpires }
    }
}
Save $rows 'privileged-members.csv'

Write-Host "5/9 Users..."
$users = Get-ADUser -Filter * -Properties Enabled, LastLogonDate, PasswordLastSet, PasswordNeverExpires, PasswordNotRequired,
            WhenCreated, Description, Title, Department, Manager, AdminCount, ServicePrincipalName, CanonicalName |
    Select-Object SamAccountName, Name, Enabled, Department, Title, Description, LastLogonDate, PasswordLastSet,
        PasswordNeverExpires, PasswordNotRequired, AdminCount, WhenCreated,
        @{n='HasSPN';e={[bool]$_.ServicePrincipalName}},
        @{n='OU';e={$_.CanonicalName -replace '/[^/]+$',''}},
        @{n='Stale90d';e={ $_.Enabled -and ($_.LastLogonDate -lt $stale) }},
        @{n='LikelyShared';e={ $_.SamAccountName -match 'admin|user|test|temp|scan|share|guest|office|reception|account|it$' }}
Save $users 'users-all.csv'
Save ($users | Where-Object Stale90d) 'users-enabled-stale-90d.csv'

Write-Host "6/9 Computers (cross-check against hardware inventory)..."
$comps = Get-ADComputer -Filter * -Properties OperatingSystem, OperatingSystemVersion, LastLogonDate, Enabled, IPv4Address, WhenCreated, Description |
    Select-Object Name, Enabled, OperatingSystem, OperatingSystemVersion, IPv4Address, LastLogonDate, WhenCreated, Description,
        @{n='Stale90d';e={ $_.LastLogonDate -lt $stale }},
        @{n='SupportFlag';e={ switch -Regex ($_.OperatingSystem) {
            'Windows 10|Windows 7|Windows 8|2008|2012' {'UNSUPPORTED'} '2016' {'EOS 2027-01-12'} default {''} } }}
Save $comps 'computers-all.csv'
$comps | Group-Object OperatingSystem | Select-Object Count, Name | Sort-Object Count -Descending | Save -file 'computers-by-os.csv'

Write-Host "7/9 GPOs..."
try { Get-GPO -All | Select-Object DisplayName, GpoStatus, CreationTime, ModificationTime | Save -file 'gpos.csv'
      Get-GPOReport -All -ReportType Html -Path "$OutDir\gpo-report.html" } catch { "GroupPolicy module not available" | Out-File "$OutDir\gpos.txt" }

Write-Host "8/9 DNS, DHCP, time..."
try { Get-DnsServerForwarder | Select-Object @{n='Forwarders';e={$_.IPAddress -join ', '}}, UseRootHint | Save -file 'dns-forwarders.csv'
      Get-DnsServerZone | Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone, DynamicUpdate | Save -file 'dns-zones.csv'
      Get-DnsServerScavenging | Select-Object * | Save -file 'dns-scavenging.csv' } catch {}
try { Get-DhcpServerInDC | Save -file 'dhcp-servers-authorized.csv'
      $dsrv = Get-DhcpServerInDC
      $scopes = foreach ($s in $dsrv) { Get-DhcpServerv4Scope -ComputerName $s.DnsName | ForEach-Object {
          $st = Get-DhcpServerv4ScopeStatistics -ComputerName $s.DnsName -ScopeId $_.ScopeId
          [pscustomobject]@{ Server=$s.DnsName; Scope=$_.ScopeId; Name=$_.Name; Start=$_.StartRange; End=$_.EndRange
                             Mask=$_.SubnetMask; State=$_.State; InUse=$st.InUse; Free=$st.Free; PercentUsed=$st.PercentageInUse } } }
      Save $scopes 'dhcp-scopes.csv' } catch {}
w32tm /query /status       > "$OutDir\time-status.txt" 2>&1
w32tm /query /configuration >> "$OutDir\time-status.txt" 2>&1

Write-Host "9/9 Certificates and PKI..."
Get-ChildItem Cert:\LocalMachine\My | Select-Object Subject, Issuer, NotAfter, @{n='DaysLeft';e={($_.NotAfter - (Get-Date)).Days}}, Thumbprint |
    Save -file 'certs-this-dc.csv'
$cfg = (Get-ADRootDSE).configurationNamingContext
Get-ADObject -SearchBase "CN=Enrollment Services,CN=Public Key Services,CN=Services,$cfg" -Filter * -Properties dNSHostName |
    Where-Object ObjectClass -eq 'pKIEnrollmentService' | Select-Object Name, dNSHostName | Save -file 'enterprise-cas.csv'

Write-Host "`nDone. Results in $OutDir"
Write-Host "Check first: dcdiag-errors-only.txt (should be nearly empty), repadmin-replsummary.txt (0 fails), privileged-members.csv"
