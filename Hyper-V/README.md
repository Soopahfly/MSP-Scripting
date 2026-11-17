# Hyper-V capacity report

`Get-HyperVCapacityReport.ps1` collects CPU and memory samples from a local Hyper-V host and its VMs. It highlights possible sizing issues and writes an HTML report, summary CSVs and raw samples.

The script does not resize VMs, change host settings, enable resource metering or reset existing metering data. It only writes report files.

## Requirements

- Run on the Hyper-V host in **Windows PowerShell 5.1 as Administrator**.
- The Hyper-V PowerShell module must be installed.
- Choose a writable output folder with space for the samples.
- Keep the PowerShell session running for the collection period.

Designed for Windows Server Hyper-V hosts with the required module and performance counters. Synthetic tests passed in Windows PowerShell 5.1; compatibility has not yet been verified on a live Hyper-V server. Run separately on each host; this is not a cluster-wide audit.

## Download and unblock

1. Open [Get-HyperVCapacityReport.ps1](Get-HyperVCapacityReport.ps1) and use **Download raw file**. Save it as `C:\Scripts\Get-HyperVCapacityReport.ps1` (create the folder if needed).
2. Review the downloaded script.
3. Open **Windows PowerShell as Administrator** and unblock the file:

```powershell
Unblock-File -LiteralPath 'C:\Scripts\Get-HyperVCapacityReport.ps1'
```

You can also right-click the file in File Explorer, select **Properties**, tick **Unblock** if present, then select **Apply** and **OK**. If there is no Unblock option, the file may not have a downloaded-file marker.

If you downloaded the repository with **Code > Download ZIP**, unblock the ZIP before extracting it:

```powershell
Unblock-File -LiteralPath "$env:USERPROFILE\Downloads\MSP-Scripting-main.zip"
```

Adjust the path to the actual download. If it has already been extracted, unblock `Get-HyperVCapacityReport.ps1` in the extracted `Hyper-V` folder instead.

### If script execution is still blocked

Unblocking a file does not change PowerShell's execution policy. Check the effective policies:

```powershell
Get-ExecutionPolicy -List
```

Where your organisation permits locally reviewed scripts, set `RemoteSigned` for the current PowerShell session only, then run the unblocked script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned
```

This setting ends when the PowerShell window closes. Group Policy settings take precedence; if policy requires signed scripts, use your organisation's approved signing process.

## Run

For a 30-minute initial check, sampling approximately every 15 seconds:

```powershell
Set-Location C:\Scripts
.\Get-HyperVCapacityReport.ps1 -DurationMinutes 30
```

For a 24-hour collection with samples approximately every 30 seconds:

```powershell
.\Get-HyperVCapacityReport.ps1 -DurationMinutes 1440 -SampleIntervalSeconds 30 -OutputDirectory C:\Reports
```

Collection time is added to the requested pause between samples. Include normal peak demand, backups and scheduled jobs in the observation window before acting on sizing suggestions. Keep VM configuration stable during collection.

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `DurationMinutes` | `30` | Collection duration, from 1 minute to 7 days. |
| `SampleIntervalSeconds` | `15` | Pause between sample passes, from 5 to 3,600 seconds. |
| `OutputDirectory` | `HyperV-Reports` under the current directory | Parent folder for a separate timestamped report folder per run. |
| `CpuHighPercent` | `90` | High CPU threshold for host and VM review. |
| `CpuLowPercent` | `20` | Low VM CPU P95 threshold used when considering excess allocation. |
| `HostFreeMemoryWarningPercent` | `10` | Low host free-RAM threshold as a percentage of physical RAM. |
| `HostReserveGB` | `4` | Planning reserve used for RAM warnings and combined startup-RAM checks. |
| `VcpuRatioWarning` | `4` | Review flag above this running-vCPU-to-logical-processor ratio. |

The free-RAM warning uses the larger of the percentage threshold and `HostReserveGB`. The reserve is a configurable allowance, not measured Hyper-V overhead.

## Output

Each run creates a folder containing:

| File | Contents |
| --- | --- |
| `Report.html` | Host summary, VM findings, thresholds and interpretation notes. |
| `Host-summary.csv` | Host hardware, allocations, observed usage and findings. |
| `VM-summary.csv` | VM configuration, sampling coverage, usage and sizing candidates. |
| `Host-samples.csv` | Timestamped host readings. |
| `VM-samples.csv` | Timestamped VM readings, including VM IDs. |

Raw samples are appended during collection. HTML and summary CSVs are generated when the run completes. Cancelling early leaves the collected samples but does not generate a final summary. Large hosts and long runs use more memory and disk space because samples are also retained in memory.

## Reading the findings

- **Possible CPU over-provisioning:** VM CPU P95 is below the low threshold, sampled peak is below 50%, and the VM has more than one vCPU. Validate workload peaks and individual vCPU hotspots before reducing the allocation.
- **Possible CPU under-provisioning:** VM CPU P95 reaches the high threshold. Check host contention, CPU caps and whether the application can use more vCPUs before adding them.
- **Host CPU pressure:** average utilisation at or above the high threshold indicates sustained aggregate saturation; a high P95 flags busy periods. Host CPU comes from Hyper-V logical processor counters, not just the host operating system's CPU usage.
- **CPU allocation ratio:** more vCPUs than logical processors does not by itself prove overload. Physical cores and logical processors are reported separately.
- **Dynamic memory:** demand reaching allocation flags pressure. The report distinguishes a VM near its maximum from one that may be waiting for memory. A minimum far above observed demand can be a reduction candidate. An unused maximum is not reserved RAM.
- **Static memory:** the report includes available demand estimates but requires guest-level checks before drawing a RAM sizing conclusion.
- **Host RAM:** low available physical RAM and combined startup allocations are planning flags. Check the Hyper-V memory balancer, guest paging and overhead before changing allocations.

P95 means the nearest-rank 95th percentile of collected point samples. CPU conclusions require at least 10 samples and 80% coverage; demand-based RAM conclusions also require sufficient valid memory samples. These are telemetry checks, not proof that the workload was representative. Missing or zero memory-demand telemetry is not treated as spare RAM.

## Limitations

This report covers local CPU and RAM. It does not assess storage capacity or latency, network performance, per-vCPU hotspots, CPU ready time, NUMA placement, guest paging or cluster N+1/failover capacity. VM CPU usage is aggregated across its allocated processors, which can hide a single busy vCPU. Memory demand is an integration-service estimate rather than an application's working set.

VM configuration is captured when each VM is first seen. Keep settings stable; migration, restart and configuration changes may invalidate comparisons. Combined startup RAM includes every VM seen during the run, including powered-off VMs, and is not a guarantee that all VMs can start together.

No automatic allocation changes are made. Confirm candidates against application requirements and a representative workload cycle.

## Validation

Run the accompanying synthetic checks from this folder:

```powershell
.\Test-HyperVCapacityReport.ps1
```

Unblock the test script too if it was downloaded. It substitutes simulated host and VM data and writes temporary test reports. Checks cover busy and idle VMs, offline VMs, missing memory demand, static memory, host saturation, low host RAM, missing host CPU telemetry, HTML escaping and CSV/HTML generation.

These checks passed under Windows PowerShell 5.1. They do not validate live Hyper-V counter availability or accuracy.

## Reference

[Microsoft: Detecting bottlenecks in a virtualized environment](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/detecting-virtualized-environment-bottlenecks)
