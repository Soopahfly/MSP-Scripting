#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Samples a local Hyper-V host and reports CPU and memory sizing candidates.
.DESCRIPTION
Run in elevated Windows PowerShell 5.1 on each Hyper-V host. Read-only except
for report files. Does not enable/reset resource metering or change VM settings.
Defaults to 30 minutes; use a representative business cycle before resizing.
Host CPU uses Hyper-V logical processor counters, not root OS CPU utilisation.
VM CPU uses Get-VM CPUUsage (aggregate utilisation of allocated virtual CPUs).
Memory demand is an estimate; static-memory guests require in-guest validation.
No storage, network, guest paging, per-vCPU bottleneck or cluster failover audit.
.EXAMPLE
.\Get-HyperVCapacityReport.ps1 -DurationMinutes 30
.EXAMPLE
.\Get-HyperVCapacityReport.ps1 -DurationMinutes 1440 -SampleIntervalSeconds 30 -OutputDirectory C:\Reports
#>
[CmdletBinding()]
param(
    [ValidateRange(1,10080)][int]$DurationMinutes = 30,
    [ValidateRange(5,3600)][int]$SampleIntervalSeconds = 15,
    [string]$OutputDirectory = (Join-Path $PWD 'HyperV-Reports'),
    [ValidateRange(1,99)][double]$CpuHighPercent = 90,
    [ValidateRange(1,50)][double]$CpuLowPercent = 20,
    [ValidateRange(1,50)][double]$HostFreeMemoryWarningPercent = 10,
    [ValidateRange(1,100)][double]$HostReserveGB = 4,
    [ValidateRange(1,32)][double]$VcpuRatioWarning = 4
)
$ErrorActionPreference = 'Stop'
Import-Module Hyper-V -ErrorAction Stop
if ($CpuLowPercent -ge $CpuHighPercent) { throw 'CpuLowPercent must be lower than CpuHighPercent.' }

function Get-Stats {
    param([object[]]$Values)
    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -eq 0) { return [pscustomobject]@{ Count=0; Average=$null; P95=$null; Maximum=$null; Minimum=$null } }
    [pscustomobject]@{
        Count=$numbers.Count
        Average=[math]::Round(($numbers | Measure-Object -Average).Average,2)
        P95=[math]::Round($numbers[[math]::Ceiling($numbers.Count * 0.95)-1],2)
        Maximum=[math]::Round($numbers[-1],2)
        Minimum=[math]::Round($numbers[0],2)
    }
}
function Get-Sum { param($Items,[string]$Property) [double](($Items | Measure-Object -Property $Property -Sum).Sum) }
function Encode { param($Text) [System.Net.WebUtility]::HtmlEncode([string]$Text) }

$system = Get-CimInstance Win32_ComputerSystem
$processors = @(Get-CimInstance Win32_Processor)
$physicalCores = Get-Sum $processors 'NumberOfCores'
$logicalProcessors = Get-Sum $processors 'NumberOfLogicalProcessors'
if ($logicalProcessors -le 0) { throw 'Cannot determine host logical processor count.' }
$ramGB = [math]::Round($system.TotalPhysicalMemory / 1GB,2)
$initialVMs = @(Get-VM)
$inventory = @{}
$samples = New-Object 'System.Collections.Generic.List[object]'
$hostSamples = New-Object 'System.Collections.Generic.List[object]'
$issues = New-Object 'System.Collections.Generic.HashSet[string]'
$runDirectory = Join-Path $OutputDirectory ('{0}-{1}-{2}' -f $env:COMPUTERNAME,(Get-Date -Format 'yyyyMMdd-HHmmss'),([guid]::NewGuid().ToString('N').Substring(0,6)))
$null = New-Item -ItemType Directory -Path $runDirectory -Force
$start = Get-Date
$end = $start.AddMinutes($DurationMinutes)
$iteration = 0
Write-Host "Sampling $env:COMPUTERNAME for $DurationMinutes minutes. Reports: $runDirectory"
do {
    $time = Get-Date
    $iteration++
    $currentVMs = @(Get-VM)
    foreach ($vm in $currentVMs) {
        $id = [string]$vm.Id
        if (-not $inventory.ContainsKey($id)) {
            $memory = Get-VMMemory -VM $vm
            $cpu = Get-VMProcessor -VM $vm
            $inventory[$id] = [pscustomobject]@{
                VMId=$id; Name=$vm.Name; InitialState=[string]$vm.State
                vCPU=[int]$vm.ProcessorCount; DynamicMemory=[bool]$memory.DynamicMemoryEnabled
                StartupGB=[math]::Round($memory.Startup/1GB,2)
                MinimumGB=[math]::Round($memory.Minimum/1GB,2)
                MaximumGB=[math]::Round($memory.Maximum/1GB,2)
                CpuMaximumPercent=$cpu.Maximum; CpuReservePercent=$cpu.Reserve
            }
        }
        $running = ([string]$vm.State -eq 'Running')
        $demand = $null
        $assigned = $null
        $cpuUsage = $null
        $pressure = $null
        if ($running) {
            $cpuUsage = [double]$vm.CPUUsage
            $assigned = [double]$vm.MemoryAssigned / 1GB
            # Zero demand is often unavailable integration-service telemetry, not zero use.
            if ($vm.MemoryDemand -gt 0 -and $vm.MemoryAssigned -gt 0) {
                $demand = [double]$vm.MemoryDemand / 1GB
                $pressure = 100.0 * $vm.MemoryDemand / $vm.MemoryAssigned
            }
        }
        $row = [pscustomobject]@{
            Timestamp=$time.ToString('o'); VMId=$id; Name=$vm.Name; State=[string]$vm.State
            vCPU=[int]$vm.ProcessorCount; CpuPercent=$cpuUsage
            AssignedGB=$assigned; DemandGB=$demand; DemandAssignedPercent=$pressure
        }
        $samples.Add($row)
        $row | Export-Csv (Join-Path $runDirectory 'VM-samples.csv') -NoTypeInformation -Append -Encoding UTF8
    }
    $hostCpu = $null
    $freeGB = $null
    try {
        # CIM performance class names are invariant on non-English Windows installations.
        $counter = Get-CimInstance -ClassName Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor -Filter "Name='_Total'"
        if ($null -eq $counter -or $null -eq $counter.PercentTotalRunTime) { throw 'Hyper-V total CPU counter unavailable.' }
        $hostCpu = [double]$counter.PercentTotalRunTime
        if ($hostCpu -lt 0 -or $hostCpu -gt 100) { $hostCpu=$null; throw 'Invalid host CPU sample.' }
    } catch { $null = $issues.Add("Host CPU telemetry missing: $($_.Exception.Message)") }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        if ($null -eq $os.FreePhysicalMemory) { throw 'Free physical memory unavailable.' }
        $freeGB = [double]$os.FreePhysicalMemory * 1KB / 1GB
    } catch { $null = $issues.Add("Host memory telemetry missing: $($_.Exception.Message)") }
    $runningVMs = @($currentVMs | Where-Object { [string]$_.State -eq 'Running' })
    $hostRow = [pscustomobject]@{
        Timestamp=$time.ToString('o'); CpuPercent=$hostCpu; FreeMemoryGB=$freeGB
        RunningVMs=$runningVMs.Count; RunningVcpu=(Get-Sum $runningVMs 'ProcessorCount')
        AssignedVMGB=((Get-Sum $currentVMs 'MemoryAssigned')/1GB)
    }
    $hostSamples.Add($hostRow)
    $hostRow | Export-Csv (Join-Path $runDirectory 'Host-samples.csv') -NoTypeInformation -Append -Encoding UTF8
    Write-Progress -Activity 'Sampling Hyper-V capacity' -Status "$iteration samples; ends $end" -PercentComplete ([math]::Min(100,100*((Get-Date)-$start).TotalSeconds/($DurationMinutes*60)))
    $remaining = ($end - (Get-Date)).TotalSeconds
    if ($remaining -gt 0) { Start-Sleep -Seconds ([int][math]::Min($SampleIntervalSeconds,[math]::Ceiling($remaining))) }
} while ((Get-Date) -lt $end)
Write-Progress -Activity 'Sampling Hyper-V capacity' -Completed

$hostCpuStats = Get-Stats @($hostSamples | ForEach-Object { $_.CpuPercent })
$hostMemoryStats = Get-Stats @($hostSamples | ForEach-Object { $_.FreeMemoryGB })
$hostFindings = New-Object 'System.Collections.Generic.List[string]'
$enoughHostCpu = $hostCpuStats.Count -ge 10 -and $hostCpuStats.Count -ge ($iteration * 0.8)
if (-not $enoughHostCpu) { $hostFindings.Add('Host CPU: insufficient telemetry; no capacity conclusion.') }
elseif ($hostCpuStats.Average -ge $CpuHighPercent) { $hostFindings.Add('Host CPU: sustained saturation; consider moving workloads or adding capacity.') }
elseif ($hostCpuStats.P95 -ge $CpuHighPercent) { $hostFindings.Add('Host CPU: high-load periods observed; inspect peaks and workload impact.') }
else { $hostFindings.Add('Host CPU: no aggregate saturation detected in this window; individual core pressure is not assessed.') }
$freeWarningGB = [math]::Max($HostReserveGB,$ramGB*$HostFreeMemoryWarningPercent/100)
if ($hostMemoryStats.Count -lt 10 -or $hostMemoryStats.Count -lt $iteration*0.8) {
    $hostFindings.Add('Host RAM: insufficient telemetry; no capacity conclusion.')
} else {
    $lowMemorySamples = @($hostSamples | Where-Object { $null -ne $_.FreeMemoryGB -and $_.FreeMemoryGB -lt $freeWarningGB }).Count
    if ($lowMemorySamples -gt 0) { $hostFindings.Add("Host RAM: below $([math]::Round($freeWarningGB,2)) GB free in $lowMemorySamples/$($hostMemoryStats.Count) samples. Check memory balancer availability and guest paging before expanding allocations.") }
    else { $hostFindings.Add('Host RAM: no low-free-memory condition detected in this window.') }
}
$maxVcpu = ($hostSamples | Measure-Object RunningVcpu -Maximum).Maximum
$ratio = [math]::Round($maxVcpu/$logicalProcessors,2)
if ($ratio -gt $VcpuRatioWarning) { $hostFindings.Add("Running vCPU/logical processor ratio exceeded ${VcpuRatioWarning}:1. This is an allocation review flag, not evidence of overload.") }
$allStartup = Get-Sum @($inventory.Values) 'StartupGB'
if ($allStartup -gt ($ramGB-$HostReserveGB)) { $hostFindings.Add('Combined startup RAM exceeds physical RAM minus the planning reserve. Simultaneous cold starts may not fit; host/VM overhead and cluster failover need separate allowance.') }

$vmReport = @(foreach ($entry in ($inventory.Values | Sort-Object Name)) {
    $rows = @($samples | Where-Object { $_.VMId -eq $entry.VMId -and $_.State -eq 'Running' })
    $cpuStats = Get-Stats @($rows | ForEach-Object { $_.CpuPercent })
    $demandStats = Get-Stats @($rows | ForEach-Object { $_.DemandGB })
    $pressureStats = Get-Stats @($rows | ForEach-Object { $_.DemandAssignedPercent })
    $assignedStats = Get-Stats @($rows | ForEach-Object { $_.AssignedGB })
    $findings = New-Object 'System.Collections.Generic.List[string]'
    $adequate = $rows.Count -ge 10 -and $rows.Count -ge $iteration*0.8
    $changedCpu = @($rows | Where-Object { $_.vCPU -ne $entry.vCPU }).Count -gt 0
    if (-not $adequate -or $changedCpu) { $findings.Add('CPU: insufficient running coverage or changed vCPU allocation; collect a stable window.') }
    elseif ($cpuStats.P95 -ge $CpuHighPercent) {
        $findings.Add('CPU: possible under-provisioning; check host contention, per-vCPU load and application parallelism before adding vCPUs.')
    } elseif ($cpuStats.P95 -lt $CpuLowPercent -and $cpuStats.Maximum -lt 50 -and $entry.vCPU -gt 1) {
        $findings.Add('CPU: possible over-provisioning; validate peak business demand and per-vCPU hotspots before reducing allocation.')
    } else { $findings.Add('CPU: no aggregate sizing flag in this window; per-vCPU hotspots can be hidden.') }
    if ($entry.CpuMaximumPercent -lt 100) { $findings.Add('CPU is capped; check the configured limit before interpreting utilisation.') }
    if (-not $adequate -or $demandStats.Count -lt 10 -or $demandStats.Count -lt $rows.Count*0.8) {
        $findings.Add('RAM: insufficient demand telemetry; check integration services and guest memory counters.')
    } elseif (-not $entry.DynamicMemory) {
        $findings.Add('RAM: static allocation; demand is advisory only. Confirm guest available RAM, paging and application cache needs before resizing.')
    } elseif ($pressureStats.P95 -ge 100) {
        if ($assignedStats.Maximum -ge $entry.MaximumGB*0.95) {
            $findings.Add('RAM: possible under-provisioning at the dynamic-memory maximum; validate guest pressure and host headroom.')
        } else { $findings.Add('RAM: demand reached/exceeded allocation; inspect host pressure and dynamic-memory response before changing limits.') }
    } elseif ($demandStats.Maximum -lt $entry.MinimumGB*0.5) {
        $findings.Add('RAM: dynamic minimum may be oversized; review guest requirements over a representative workload cycle.')
    } else { $findings.Add('RAM: no dynamic-memory sizing flag. An unused maximum is a ceiling, not reserved RAM.') }
    [pscustomobject]@{
        Name=$entry.Name; VMId=$entry.VMId; InitialState=$entry.InitialState; vCPU=$entry.vCPU
        RunningSamples=$rows.Count; CoveragePercent=[math]::Round(100*$rows.Count/$iteration,1)
        CpuAveragePercent=$cpuStats.Average; CpuP95Percent=$cpuStats.P95; CpuPeakPercent=$cpuStats.Maximum
        CpuMaximumPercent=$entry.CpuMaximumPercent; CpuReservePercent=$entry.CpuReservePercent
        DynamicMemory=$entry.DynamicMemory; StartupGB=$entry.StartupGB; MinimumGB=$entry.MinimumGB; MaximumGB=$entry.MaximumGB
        AssignedPeakGB=$assignedStats.Maximum; DemandP95GB=$demandStats.P95; DemandPeakGB=$demandStats.Maximum
        DemandSamples=$demandStats.Count; DemandAssignedP95Percent=$pressureStats.P95
        Findings=($findings -join ' ')
    }
})
$hostReport = [pscustomobject]@{
    HostName=$env:COMPUTERNAME; Start=$start.ToString('o'); End=(Get-Date).ToString('o'); Samples=$iteration
    PhysicalCores=$physicalCores; LogicalProcessors=$logicalProcessors; PhysicalRAMGB=$ramGB
    PlanningReserveGB=$HostReserveGB; SeenVMs=$inventory.Count; PeakRunningVcpu=$maxVcpu
    PeakVcpuPerLogicalProcessor=$ratio; StartupGBAllSeenVMs=$allStartup
    CpuSamples=$hostCpuStats.Count; CpuAveragePercent=$hostCpuStats.Average; CpuP95Percent=$hostCpuStats.P95
    CpuPeakPercent=$hostCpuStats.Maximum; MinimumFreeRAMGB=$hostMemoryStats.Minimum
    PeakAssignedVMGB=($hostSamples | Measure-Object AssignedVMGB -Maximum).Maximum
    Findings=($hostFindings -join ' ')
}
$hostReport | Export-Csv (Join-Path $runDirectory 'Host-summary.csv') -NoTypeInformation -Encoding UTF8
$vmReport | Export-Csv (Join-Path $runDirectory 'VM-summary.csv') -NoTypeInformation -Encoding UTF8
$notes = @(
    'Sizing candidates are heuristics, not automatic resize instructions. Capture peak business activity, backups and batch jobs; a quiet sample cannot establish safe reductions.',
    'P95 is the nearest-rank 95th percentile of point samples. Short spikes between samples can be missed. Ten samples and 80% coverage are minimum telemetry checks, not proof of representative demand.',
    'VM CPU is aggregate Get-VM utilisation. Individual virtual CPU hotspots, CPU ready time, scheduler constraints, NUMA and guest paging are not measured.',
    'MemoryDemand is an integration-service estimate, not application working set. Static-memory guests require in-guest analysis. Dynamic maximums are not reservations.',
    'Allocation settings are recorded when a VM is first seen. Keep settings stable during collection; migrating VMs and changing configuration can invalidate sizing comparisons.',
    'This is a local CPU/RAM audit, not cluster N+1, storage capacity/latency, network or high-availability certification. The RAM reserve is a configurable planning allowance, not measured Hyper-V overhead.',
    "Thresholds: CPU high $CpuHighPercent%; CPU low $CpuLowPercent%; low host RAM below $([math]::Round($freeWarningGB,2)) GB; vCPU/LP review ratio ${VcpuRatioWarning}:1. Logical threads are not equivalent to physical cores."
) + @($issues)
$noteHtml = ($notes | ForEach-Object { '<li>' + (Encode $_) + '</li>' }) -join "`n"
$hostHtml = $hostReport | ConvertTo-Html -Fragment -As List | Out-String
$vmHtml = $vmReport | Select-Object Name,vCPU,RunningSamples,CoveragePercent,CpuAveragePercent,CpuP95Percent,CpuPeakPercent,DynamicMemory,StartupGB,MinimumGB,MaximumGB,AssignedPeakGB,DemandPeakGB,Findings | ConvertTo-Html -Fragment | Out-String
$html = @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>Hyper-V capacity report</title>
<style>body{font-family:Segoe UI,Arial;margin:28px;color:#172b4d}table{border-collapse:collapse;font-size:13px}td,th{border:1px solid #ccd6df;padding:8px;text-align:left;vertical-align:top}th{background:#eaf0f6}li{margin-bottom:8px}h1,h2{color:#174c74}</style></head>
<body><h1>Hyper-V capacity report: $(Encode $env:COMPUTERNAME)</h1><h2>Interpretation and coverage</h2><ul>$noteHtml</ul>
<h2>Host</h2>$hostHtml<h2>Virtual machines</h2>$vmHtml
<p>Reference: <a href="https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/detecting-virtualized-environment-bottlenecks">Microsoft Hyper-V bottleneck guidance</a>.</p></body></html>
"@
$html | Set-Content (Join-Path $runDirectory 'Report.html') -Encoding UTF8
$hostReport | Format-List | Out-Host
$vmReport | Select-Object Name,vCPU,CpuP95Percent,DemandPeakGB,Findings | Format-Table -Wrap | Out-Host
Write-Host "Report complete: $(Join-Path $runDirectory 'Report.html')"
if ($issues.Count -gt 0) { Write-Warning 'Some telemetry was unavailable. See report notes; missing readings are not treated as zero.' }
