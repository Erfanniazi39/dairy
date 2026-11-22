# G1 · Step 2: Server Assessment

**Goal of this step:** know exactly what the company server is, what runs on it, how healthy it is, how well it is protected, and what would happen if it stopped.

**Why it matters:** with only one server, everything important probably lives there: files, accounting data, maybe logins. It is the most important machine in the company and the biggest single point of failure.

**Time needed:** about 2–3 hours.

---

## 0. Before you start

### Rules for this step: look, don't touch
- **Do not** restart the server, install software, change settings, delete files, or touch RAID/disk settings.
- **Do not** open the case or pull cables while it is running.
- If you find something urgent (a failing disk, no backup at all), **write it down first**, then tell management. Fixing happens in G2/G3, with a rollback plan.

### What you need
- An administrator account on the server
- A USB stick containing `Get-G1Inventory.ps1`, with an empty folder `G1\server` on it
- Your phone (for photos)
- This document, to fill in the answers

### How to open an Administrator PowerShell
1. Log in to the server (sitting in front of it, or by Remote Desktop).
2. Click Start, type `powershell`, right-click **Windows PowerShell**, then **Run as administrator**.
3. Every command below runs in that window. **All of them only read information.**

> Tip: in the commands below, `E:` is the USB stick. Change it if your USB has a different letter (check in File Explorer).

---

## 1. Physical check (look at the machine)

Go to where the server is and record:

| What to check | How | Write down |
|---|---|---|
| Location | Where is it? A locked room, an office corner, under a desk? | |
| Who can physically reach it | Is the room locked? Who has the key? | |
| Temperature / airflow | Is the room hot? Are fans blocked? Is there dust on the front? | |
| Form factor | Tower or rack-mounted? | |
| Brand and model | Label on the front or top (e.g. HPE ProLiant ML350, Dell PowerEdge T340) | |
| Service tag / serial number | Sticker on the back or side, or a pull-out tag on the front | |
| Warning lights | Any orange/red lights on the front, on disks or power supplies? | |
| Power supplies | One or two power cables? (Two = redundant PSU) | |
| UPS | Is the server plugged into a UPS, or directly into the wall? | |
| Cables | Is there a USB/serial cable between the UPS and the server? | |
| Labels | Is the server labeled with its name? | |

📷 **Take photos:** front, back (cables), the serial-number sticker, the UPS and its label.

---

## 2. Basic identity: what server is it?

### 2.1 Run the inventory script first
This collects most of the basic facts in one go:

```powershell
powershell -ExecutionPolicy Bypass -File E:\Get-G1Inventory.ps1 -OutDir E:\G1\server
```

It creates `<SERVERNAME>-summary.csv`, `-software.csv`, `-listening.csv` and `-roles.txt` on the USB.

### 2.2 Confirm the key facts by hand

```powershell
# Name, Windows edition, version, install date, last boot
Get-CimInstance Win32_OperatingSystem | Select-Object CSName, Caption, Version, BuildNumber, InstallDate, LastBootUpTime

# Brand, model, serial number, BIOS date
Get-CimInstance Win32_ComputerSystem | Select-Object Manufacturer, Model, TotalPhysicalMemory, Domain, PartOfDomain
Get-CimInstance Win32_BIOS | Select-Object SerialNumber, SMBIOSBIOSVersion, ReleaseDate

# CPU
Get-CimInstance Win32_Processor | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors
```

### 2.3 Windows license and activation

```powershell
slmgr /dli
```
A small window shows the edition and **License Status** (it should say *Licensed*). Write down the edition (Standard / Essentials / Datacenter).

### 2.4 Is this Windows version still supported?

| Windows Server version | Status (verify on Microsoft's lifecycle page) |
|---|---|
| 2008 / 2008 R2 | ❌ Unsupported: high risk |
| 2012 / 2012 R2 | ❌ Unsupported since Oct 2023: high risk |
| 2016 | ⚠️ Support ends **12 Jan 2027**, about 2 months from now: plan the replacement |
| 2019 | ✅ Supported until Jan 2029 |
| 2022 | ✅ Supported until Oct 2031 |
| 2025 | ✅ Supported |

### 2.5 Age and warranty
- Check the BIOS date (from 2.2) and any purchase invoice. A server older than **5–6 years** is near the end of its normal life.
- The vendor warranty websites (HPE, Dell, Lenovo) may be blocked from Iran. If they are, use the purchase invoice date and write "warranty unknown".

**Write down:**

| Item | Value |
|---|---|
| Server name | |
| Brand / model | |
| Serial number | |
| CPU / cores | |
| RAM (GB) | |
| Windows version and edition | |
| Activated? | |
| Support status | |
| Approximate age / purchase date | |
| Warranty | |

---

## 3. What runs on the server

This is the most important part. The question is: **"If this server is off for a day, what stops working?"**

### 3.1 Windows roles (built-in services)

```powershell
Get-WindowsFeature | Where-Object { $_.Installed -and $_.FeatureType -eq 'Role' } | Select-Object DisplayName, Name
```

What the common roles mean:

| Role you see | What it means |
|---|---|
| Active Directory Domain Services | The server manages company logins (it is a **domain controller**) |
| DNS Server | It answers name lookups for the network |
| DHCP Server | It gives IP addresses to PCs |
| File and Storage Services / File Server | It shares folders |
| Print Server | It shares printers |
| Hyper-V | It runs virtual machines (other servers inside it) |
| Web Server (IIS) | It hosts a website or web application |
| Remote Desktop Services | Users work on it remotely |

### 3.2 Shared folders

```powershell
# All shares (ignore ones ending in $ like ADMIN$, C$, IPC$, which are built in)
Get-SmbShare | Select-Object Name, Path, Description

# Who has access to each share
Get-SmbShare | Where-Object Name -notlike '*$' | ForEach-Object { Get-SmbShareAccess -Name $_.Name } |
    Select-Object Name, AccountName, AccessRight

# Size of each shared folder (may take a few minutes on large folders)
Get-SmbShare | Where-Object { $_.Name -notlike '*$' -and $_.Path } | ForEach-Object {
    $size = (Get-ChildItem $_.Path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    [pscustomobject]@{ Share = $_.Name; Path = $_.Path; SizeGB = [math]::Round($size/1GB, 1) }
}

# Who is connected right now (shows which PCs use the server)
Get-SmbSession | Select-Object ClientComputerName, ClientUserName, NumOpens
```

⚠️ **Red flag:** a share where `Everyone` has `Full` access.

### 3.3 Installed programs
Open `<SERVERNAME>-software.csv` from the USB in Excel. Look especially for:
- **Accounting / ERP / payroll software** (for example Sepidar, Hamkaran System, Mahak, Rahkaran, or similar)
- **Database servers**: Microsoft SQL Server, MySQL, PostgreSQL
- **Backup software**
- **Remote-access tools**: AnyDesk, TeamViewer, and similar. Note who uses them.
- **Antivirus** (Kaspersky, ESET, Defender, and so on)

### 3.4 Databases (common with Iranian accounting software)

```powershell
# Is SQL Server installed? Which instances?
Get-Service | Where-Object { $_.Name -like 'MSSQL*' -or $_.Name -like 'MySQL*' -or $_.Name -like 'postgresql*' } |
    Select-Object Name, DisplayName, Status

# Where are the SQL database files? (searches all fixed drives; can take several minutes)
Get-PSDrive -PSProvider FileSystem | Where-Object Free | ForEach-Object {
    Get-ChildItem "$($_.Root)" -Recurse -Include *.mdf, *.ldf -ErrorAction SilentlyContinue
} | Select-Object FullName, @{n='SizeMB';e={[math]::Round($_.Length/1MB)}}, LastWriteTime
```

If SQL Server exists, write down: the instance name, which program uses it, the database file locations and sizes.

### 3.5 Non-Microsoft services (programs that run in the background)

```powershell
Get-CimInstance Win32_Service |
    Where-Object { $_.State -eq 'Running' -and $_.PathName -notmatch '\\Windows\\' } |
    Select-Object DisplayName, Name, StartName, PathName | Format-Table -AutoSize -Wrap
```

`StartName` shows which account each service runs as. If a service runs as a **normal user account**, note it: if that user's password changes, the service breaks.

### 3.6 Network ports the server is listening on
Open `<SERVERNAME>-listening.csv`. Each line is a program waiting for connections. Common ones:

| Port | Usually means |
|---|---|
| 53 | DNS |
| 88, 389, 636, 3268 | Active Directory |
| 445 | File sharing (SMB) |
| 1433 | SQL Server |
| 3389 | Remote Desktop |
| 80 / 443 | Web server |

Any port you cannot explain is an unknown application. Ask around until you find out what it is.

### 3.7 Scheduled tasks (things that run automatically)

```powershell
Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
    Select-Object TaskName, State, @{n='RunsAs';e={$_.Principal.UserId}},
        @{n='Action';e={($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join '; '}}
```

Look for backup jobs, scripts that copy files, and database maintenance.

### 3.8 Ask people
Ask the manager and one or two key users (accounting especially):
- "What do you use on the server every day?"
- "If the server stopped for a full day, what could you not do?"
- "Who installed the accounting software, and who supports it? Is there a support contract?"

**Write down: Server services list**

| Service / application | Used by | Data location | Size | How important (1–3) | Who supports it |
|---|---|---|---|---|---|
| e.g. File share "Finance" | Accounting | D:\Shares\Finance | 40 GB | 1 | IT |
| | | | | | |

---

## 4. Disks and storage

### 4.1 Disks and free space

```powershell
# Physical disks: model, size, type (SSD/HDD), health
Get-PhysicalDisk | Select-Object FriendlyName, MediaType, @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, HealthStatus, OperationalStatus

# Volumes (C:, D:, ...) with free space
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, FileSystemLabel,
    @{n='SizeGB';e={[math]::Round($_.Size/1GB)}}, @{n='FreeGB';e={[math]::Round($_.SizeRemaining/1GB)}},
    @{n='FreePct';e={[math]::Round($_.SizeRemaining/$_.Size*100)}}, HealthStatus
```

⚠️ **Red flags:** any volume with **less than 20% free**, or any disk whose `HealthStatus` is not *Healthy*.

### 4.2 Disk wear and errors

```powershell
Get-PhysicalDisk | Get-StorageReliabilityCounter |
    Select-Object DeviceId, Temperature, Wear, ReadErrorsUncorrected, WriteErrorsUncorrected, PowerOnHours
```
(Some RAID controllers hide these values, so blank results are normal there.)

```powershell
# Disk and file-system errors in the last 90 days
Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2,3; StartTime=(Get-Date).AddDays(-90) } -ErrorAction SilentlyContinue |
    Where-Object { $_.ProviderName -match 'disk|Ntfs|storahci|stornvme|iaStor|megasas|percsas|HpCISSs|smartpqi' } |
    Group-Object ProviderName, Id | Select-Object Count, Name | Sort-Object Count -Descending
```

⚠️ **Red flag:** any results here, especially `disk` event ID **7** (bad block), **51**, **153**, or `Ntfs` event ID **55**. These can mean a disk is failing. **Report this immediately, before anything else.**

### 4.3 Is there RAID (disk mirroring)?

RAID means that if one disk dies, the data survives on the others. Find out which kind you have:

**a) Hardware RAID controller** (most branded servers)
- In Device Manager → *Storage controllers*, look for names like *Smart Array* / *SmartRAID* (HPE), *PERC* (Dell), *MegaRAID* / *LSI* / *Broadcom*, *ThinkSystem RAID* (Lenovo).
- Check the RAID status **without rebooting**:
  - HPE: open **iLO** in a browser (the iLO address is on a pull-out tag), or the *Smart Storage Administrator* app if installed
  - Dell: open **iDRAC** in a browser, or *OpenManage Server Administrator* if installed
  - Others: the vendor's RAID tool (for example *MegaRAID Storage Manager* or `storcli`)
- Write down the RAID level (RAID 1, 5, 10…), the number of disks, and the status of every disk (*Optimal / Degraded / Failed / Rebuilding*).

**b) Windows software RAID**

```powershell
# Storage Spaces
Get-StoragePool -IsPrimordial $false -ErrorAction SilentlyContinue | Select-Object FriendlyName, HealthStatus
Get-VirtualDisk -ErrorAction SilentlyContinue | Select-Object FriendlyName, ResiliencySettingName, HealthStatus, OperationalStatus
```
Also open **Disk Management** (`diskmgmt.msc`): a volume shown as *Mirrored* means software RAID 1.

**c) Intel RST** (common on desktop-class servers): open the *Intel Rapid Storage Technology* app if installed.

**d) No RAID:** one disk, or disks used separately. ⚠️ **High risk:** one disk failure = data loss and downtime.

⚠️ **Red flag:** RAID status *Degraded*. One disk has already failed and there is no protection left. **Report this immediately.**

**Write down: Storage**

| Volume | Size GB | Free GB | Free % | Contains |
|---|---|---|---|---|
| C: | | | | Windows |
| D: | | | | |

| Item | Value |
|---|---|
| Number of physical disks, type (SSD/HDD), size | |
| RAID type and level | |
| RAID status | |
| Disk errors in event log (last 90 days) | |

### 4.4 Growth
There is no history yet. Write down today's used space per volume. When you repeat the check next month, the difference is your growth rate.

---

## 5. Health and maintenance

```powershell
# Last installed updates
Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 5 HotFixID, Description, InstalledOn

# How long since the last restart
(Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime

# Antivirus status (Defender)
Get-MpComputerStatus -ErrorAction SilentlyContinue | Select-Object AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureLastUpdated
# If you use another antivirus (Kaspersky, ESET...), open its window and note the last update date.

# Most frequent errors in the last 30 days
Get-WinEvent -FilterHashtable @{ LogName='System','Application'; Level=1,2; StartTime=(Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
    Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 15 Count, Name

# Unexpected shutdowns (power loss / crash) in the last 180 days
Get-WinEvent -FilterHashtable @{ LogName='System'; Id=41,6008; StartTime=(Get-Date).AddDays(-180) } -ErrorAction SilentlyContinue |
    Select-Object TimeCreated, Id, Message

# Time source
w32tm /query /status
```

⚠️ **Red flags:**
- The last update is **more than 2 months old**
- Antivirus is off or out of date
- Event 41 or 6008 appears often. That means power cuts or crashes, which points to a UPS problem.

**Write down:**

| Item | Value |
|---|---|
| Last update installed (date) | |
| Days since last restart | |
| Antivirus product + last update | |
| Unexpected shutdowns (last 180 days) | |
| Top recurring errors | |

---

## 6. Access and security

```powershell
# Members of the local Administrators group (works on non-English Windows)
$adm = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
net localgroup "$adm"

# Local user accounts on the server
Get-CimInstance Win32_UserAccount -Filter "LocalAccount=True" | Select-Object Name, Disabled, PasswordExpires, Description

# Is Remote Desktop enabled?
(Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections   # 0 = enabled

# Who logged in by Remote Desktop in the last 30 days, and from which IP
Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4624; StartTime=(Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
    Where-Object { $_.Properties[8].Value -eq 10 } |
    ForEach-Object { [pscustomobject]@{ Time=$_.TimeCreated; User=$_.Properties[5].Value; FromIP=$_.Properties[18].Value } } |
    Group-Object User, FromIP | Select-Object Count, Name

# Failed logins in the last 7 days (many = someone guessing passwords)
(Get-WinEvent -FilterHashtable @{ LogName='Security'; Id=4625; StartTime=(Get-Date).AddDays(-7) } -ErrorAction SilentlyContinue).Count

# Is SMBv1 (old, insecure file-sharing protocol) enabled?
Get-SmbServerConfiguration | Select-Object EnableSMB1Protocol
```

Also find out (by asking):
- Who knows the server's administrator password? Is it shared between several people?
- Is the password written down somewhere? Where?
- Does any outside company (accounting software vendor, previous IT person) have remote access? How: AnyDesk, TeamViewer, RDP?
- Can the server be reached by Remote Desktop **from the internet**? You will confirm this on the router in step 5 (network), but write down any clues now: RDP logins from IP addresses outside your office range, or hundreds of failed logins.

⚠️ **Red flags:**
- Many people share one admin account
- Former employees or vendors still have access
- RDP is reachable from the internet
- Hundreds or thousands of failed logins
- SMBv1 is `True`

---

## 7. Is the server a domain controller?

```powershell
(Get-CimInstance Win32_ComputerSystem).DomainRole
```

| Result | Meaning | What next |
|---|---|---|
| 0 or 2 | Standalone (no domain) | Users log in with local PC accounts. Note this. |
| 3 | Member of a domain | Some other machine is the domain controller. Find it! |
| 4 or 5 | **This server is a domain controller** | Run `Get-G1ADHealth.ps1` on it (below) |

If the result is 4 or 5:

```powershell
powershell -ExecutionPolicy Bypass -File E:\Get-G1ADHealth.ps1 -OutDir E:\G1\server\AD
```

⚠️ **Note:** if this one server is the **only** domain controller, then when it fails, nobody can log in to the domain. That is a top-10 risk. (G5 fixes it.)

---

## 8. Backups on this server

Here you only **find out** what exists. The test restore is item 7 of G1.

```powershell
# Is Windows Server Backup installed and used?
Get-WindowsFeature Windows-Server-Backup | Select-Object Installed
wbadmin get versions        # lists existing backups (date, target)
wbadmin get status          # running job, if any

# Shadow copies ("Previous Versions") of shared folders
vssadmin list shadowstorage
vssadmin list shadows | Select-String 'creation time|Original Volume'
```

Also check:
- The software list (3.3) for backup programs (Veeam, Acronis, Cobian, Uranium, etc.). Open the program and note the jobs, schedule, destination and **last successful run**.
- The scheduled tasks (3.7) for scripts that copy files somewhere.
- The accounting software's own backup function: where it saves, how often, and who does it.
- Where the backups go: the same disk? An external USB drive? Is it always connected? (Always connected = ransomware deletes it too.) Does a copy ever leave the building?

**Write down: Backups**

| What is backed up | Method / software | How often | Destination | Last successful | Copy offsite/offline? |
|---|---|---|---|---|---|
| | | | | | |

⚠️ **Red flags:**
- No backup at all
- The backup is only on the same server
- The only backup is a USB disk that is always plugged in
- Nobody knows when the last backup succeeded

---

## 9. UPS and power

| Check | How | Write down |
|---|---|---|
| Is there a UPS? | Follow the server's power cable | |
| Brand, model, capacity (VA/W) | Label on the UPS | |
| Battery age | Sticker on the battery, or purchase date. Batteries usually last **3–5 years**. | |
| What else is plugged into it? | Switch, router, monitor? | |
| Estimated runtime | UPS display or software (shows minutes on battery) | |
| Is the UPS connected to the server by cable? | USB or serial cable between them | |
| Is shutdown software installed? | Look for PowerChute (APC), ViewPower, WinPower, or similar in the software list | |

```powershell
# If the UPS is connected by USB, Windows usually sees it as a battery
Get-CimInstance Win32_Battery | Select-Object Name, EstimatedChargeRemaining, EstimatedRunTime, Status
```

❗ **Do not test the UPS by unplugging it now.** A real power test needs a maintenance window and a working backup first, so it is done in G2.

⚠️ **Red flags:**
- No UPS
- A UPS with no shutdown connection to the server (on a long power cut, the server crashes when the battery runs out)
- Battery older than 4 years
- Frequent event 41/6008 from section 5

---

## 10. Final summary sheet

Fill this in at the end. It goes into the G1 inventory.

| Area | Finding | OK / Warning / Critical |
|---|---|---|
| Hardware age / warranty | | |
| Windows version support | | |
| Roles / what runs on it | | |
| Critical applications | | |
| Disk health | | |
| RAID | | |
| Free space | | |
| Updates | | |
| Antivirus | | |
| Admin access / passwords | | |
| Remote access (RDP / AnyDesk) | | |
| Domain controller? | | |
| Backups | | |
| UPS / power | | |
| Physical security / cooling | | |

### Risks to carry into the G1 risk register
Every **Warning** or **Critical** item above becomes a line in the risk register. Typical ones for a single small-company server:
- Single server = single point of failure for files, accounting and logins
- No tested backup, or the backup is on the same machine
- No RAID, or degraded RAID
- Windows Server 2012/2016 out of support or ending soon
- No UPS shutdown integration
- Shared admin password, or outside vendor access with no control
- RDP open to the internet

---

## 11. When you finish

Send me (or connect the USB folder in the Claude desktop app):
1. The files in `E:\G1\server\` (summary, software, listening, roles, AD folder if it exists)
2. Your filled-in tables, or just the summary sheet from section 10
3. The photos, if anything looked wrong

I will help you read the results, spot the risks and write them into the risk register. Then we move on to **step 3: computers**.
