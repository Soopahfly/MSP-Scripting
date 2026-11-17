# Synthetic end-to-end validation; no Hyper-V host or real collection is used.
$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot 'Get-HyperVCapacityReport.ps1') -Raw
$tokens=$null; $errors=$null
$null = [System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$source = $source -replace '(?m)^#Requires.*$', ''
function Import-Module { param($Name) }
function Start-Sleep { param($Seconds) }
$script:tick=0
function Get-Date {
    param($Format)
    $script:tick++
    $d = [datetime]'2026-11-17T12:00:00'
    $d = $d.AddSeconds($script:tick)
    if ($Format) { return $d.ToString($Format) }
    return $d
}
function Get-CimInstance {
    param($ClassName,$Filter)
    switch ($ClassName) {
        'Win32_ComputerSystem' { [pscustomobject]@{TotalPhysicalMemory=64GB} }
        'Win32_Processor' { [pscustomobject]@{NumberOfCores=8;NumberOfLogicalProcessors=16} }
        'Win32_OperatingSystem' { [pscustomobject]@{FreePhysicalMemory=2GB/1KB} }
        'Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor' {
            if ($script:missingCpu) { throw 'Synthetic counter failure' }
            [pscustomobject]@{PercentTotalRunTime=95}
        }
        default { throw "Unexpected class $ClassName" }
    }
}
function Get-VM {
    @(
        [pscustomobject]@{Id='1';Name='Busy <VM>';State='Running';ProcessorCount=4;CPUUsage=96;MemoryAssigned=8GB;MemoryDemand=9GB},
        [pscustomobject]@{Id='2';Name='Idle';State='Running';ProcessorCount=4;CPUUsage=2;MemoryAssigned=4GB;MemoryDemand=1GB},
        [pscustomobject]@{Id='3';Name='Offline';State='Off';ProcessorCount=2;CPUUsage=0;MemoryAssigned=0;MemoryDemand=0},
        [pscustomobject]@{Id='4';Name='No telemetry';State='Running';ProcessorCount=2;CPUUsage=25;MemoryAssigned=4GB;MemoryDemand=0},
        [pscustomobject]@{Id='5';Name='Static';State='Running';ProcessorCount=2;CPUUsage=25;MemoryAssigned=4GB;MemoryDemand=1GB}
    )
}
function Get-VMMemory {
    param($VM)
    [pscustomobject]@{DynamicMemoryEnabled=($VM.Id -ne '5');Startup=4GB;Minimum=4GB;Maximum=8GB}
}
function Get-VMProcessor { param($VM) [pscustomobject]@{Maximum=100;Reserve=0} }
$testRoot = Join-Path $env:TEMP ('HyperVCapacityTest-' + [guid]::NewGuid().ToString('N'))
foreach ($missing in @($false,$true)) {
    $script:missingCpu=$missing
    $script:tick=0
    $caseRoot = Join-Path $testRoot ([string]$missing)
    & ([scriptblock]::Create($source)) -DurationMinutes 1 -OutputDirectory $caseRoot
    $folder = Get-ChildItem $caseRoot -Directory | Select-Object -First 1
    $vms = Import-Csv (Join-Path $folder.FullName 'VM-summary.csv')
    $hostResult = Import-Csv (Join-Path $folder.FullName 'Host-summary.csv')
    if (($vms | Where-Object Name -eq 'Busy <VM>').Findings -notmatch 'possible under-provisioning') { throw 'Busy VM classification failed' }
    if (($vms | Where-Object Name -eq 'Idle').Findings -notmatch 'possible over-provisioning') { throw 'Idle VM classification failed' }
    if (($vms | Where-Object Name -eq 'Offline').Findings -notmatch 'insufficient') { throw 'Offline VM classification failed' }
    if (($vms | Where-Object Name -eq 'No telemetry').Findings -notmatch 'insufficient demand telemetry') { throw 'Missing demand classification failed' }
    if (($vms | Where-Object Name -eq 'Static').Findings -notmatch 'static allocation') { throw 'Static memory classification failed' }
    if ($missing -and $hostResult.Findings -notmatch 'CPU: insufficient telemetry') { throw 'Missing CPU classification failed' }
    if (-not $missing -and $hostResult.Findings -notmatch 'sustained saturation') { throw 'Host saturation classification failed' }
    if ($hostResult.Findings -notmatch 'Host RAM: below') { throw 'Low host RAM classification failed' }
    $html=Get-Content (Join-Path $folder.FullName 'Report.html') -Raw
    if ($html -notmatch 'Busy &lt;VM&gt;') { throw 'HTML escaping failed' }
}
Write-Host "PASS: synthetic classification, missing telemetry, HTML escaping and CSV/HTML output. Test output: $testRoot"
