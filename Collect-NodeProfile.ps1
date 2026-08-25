[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$expectedCommit = '7ea40ee98acb416787863aee935dbb99491acad5'

$computer = Get-CimInstance Win32_ComputerSystem
$operatingSystem = Get-CimInstance Win32_OperatingSystem
$processors = @(Get-CimInstance Win32_Processor)
$bios = Get-CimInstance Win32_BIOS

$video = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [ordered]@{
        Name = $_.Name
        DriverVersion = $_.DriverVersion
        PnpDeviceId = $_.PNPDeviceID
        AdapterCompatibility = $_.AdapterCompatibility
    }
})

$nvidia = @()
$nvidiaSmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
if ($nvidiaSmi) {
    $rows = @(& $nvidiaSmi.Source `
        --query-gpu=index,name,memory.total,memory.free,compute_cap,driver_version,pci.bus_id `
        --format=csv,noheader,nounits 2>$null)
    if ($LASTEXITCODE -eq 0) {
        $nvidia = @($rows | ForEach-Object {
            $parts = $_ -split ',\s*'
            if ($parts.Count -lt 7) { return }
            [ordered]@{
                Index = [int]$parts[0]
                Name = $parts[1]
                MemoryTotalMiB = [int]$parts[2]
                MemoryFreeMiB = [int]$parts[3]
                ComputeCapability = $parts[4]
                CmakeCudaArchitecture = $parts[4] -replace '\.', ''
                DriverVersion = $parts[5]
                PciBusId = $parts[6]
            }
        })
    }
}

$network = @(Get-NetAdapter | ForEach-Object {
    $adapter = $_
    $addresses = @(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue | Where-Object AddressState -ne 'Tentative' | ForEach-Object {
            "{0}/{1}" -f $_.IPAddress, $_.PrefixLength
        })
    [ordered]@{
        Name = $adapter.Name
        Description = $adapter.InterfaceDescription
        Status = [string]$adapter.Status
        LinkSpeed = [string]$adapter.LinkSpeed
        MacAddress = $adapter.MacAddress
        MtuBytes = $adapter.MtuSize
        IPv4 = $addresses
    }
})

$vulkanSummary = $null
$vulkanInfo = Get-Command vulkaninfo -ErrorAction SilentlyContinue
if ($vulkanInfo) {
    $vulkanSummary = (& $vulkanInfo.Source --summary 2>&1 | Out-String).Trim()
}

$hipSummary = $null
$hipArchitectures = @()
$hipInfo = Get-Command hipInfo, rocminfo -ErrorAction SilentlyContinue | Select-Object -First 1
if ($hipInfo) {
    $hipSummary = (& $hipInfo.Source 2>&1 | Out-String).Trim()
    $hipArchitectures = @([regex]::Matches($hipSummary, '\bgfx[1-9][0-9a-f]{3,}\b') |
        ForEach-Object Value | Sort-Object -Unique)
}

$volumes = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object DriveType -eq 'Fixed' | ForEach-Object {
    [ordered]@{
        DriveLetter = $_.DriveLetter
        FileSystem = $_.FileSystem
        SizeGiB = [math]::Round($_.Size / 1GB, 2)
        FreeGiB = [math]::Round($_.SizeRemaining / 1GB, 2)
        HealthStatus = [string]$_.HealthStatus
    }
})

$pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object {
    [ordered]@{
        Name = $_.Name
        AllocatedMiB = $_.AllocatedBaseSize
        CurrentUsageMiB = $_.CurrentUsage
        PeakUsageMiB = $_.PeakUsage
    }
})

$powerPlan = (& powercfg.exe /getactivescheme 2>$null | Out-String).Trim()
$physicalCores = ($processors | Measure-Object -Property NumberOfCores -Sum).Sum
$logicalProcessors = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

[ordered]@{
    SchemaVersion = 3
    Timestamp = (Get-Date).ToString('o')
    ExpectedSourceCommit = $expectedCommit
    Computer = [ordered]@{
        Name = $env:COMPUTERNAME
        Manufacturer = $computer.Manufacturer
        Model = $computer.Model
        BiosVersion = ($bios.SMBIOSBIOSVersion -join ', ')
        TotalMemoryGiB = [math]::Round($computer.TotalPhysicalMemory / 1GB, 2)
        FreeMemoryGiB = [math]::Round(($operatingSystem.FreePhysicalMemory * 1KB) / 1GB, 2)
    }
    OperatingSystem = [ordered]@{
        Caption = $operatingSystem.Caption
        Version = $operatingSystem.Version
        BuildNumber = $operatingSystem.BuildNumber
        LastBoot = $operatingSystem.LastBootUpTime
    }
    Cpu = [ordered]@{
        Names = @($processors.Name)
        PhysicalCores = $physicalCores
        LogicalProcessors = $logicalProcessors
    }
    VideoControllers = $video
    Nvidia = $nvidia
    VulkanSummary = $vulkanSummary
    HipArchitectures = $hipArchitectures
    HipSummary = $hipSummary
    Network = $network
    Volumes = $volumes
    PageFiles = $pageFiles
    ActivePowerPlan = $powerPlan
} | ConvertTo-Json -Depth 10
