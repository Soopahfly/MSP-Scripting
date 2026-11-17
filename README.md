# MSP-Scripting

A selection of scripts, and how they work.

## Scripts

| Script | What it does | Guide |
| --- | --- | --- |
| [Get-HyperVCapacityReport.ps1](Hyper-V/Get-HyperVCapacityReport.ps1) | Samples VM and host CPU/RAM usage to identify possible over- and under-provisioning. Produces HTML and CSV reports without changing Hyper-V settings. | [Requirements, download/unblock instructions and examples](Hyper-V/README.md) |

## Downloaded PowerShell files

Download the script using GitHub's **Download raw file** button. Review it, then unblock the downloaded file before running it:

```powershell
Unblock-File -LiteralPath 'C:\Scripts\Get-HyperVCapacityReport.ps1'
```

Alternatively, right-click the file in File Explorer, select **Properties**, tick **Unblock** if shown, then select **Apply**.

For **Code > Download ZIP**, unblock the ZIP before extracting it. If you already extracted it, unblock the individual script. Unblocking removes the downloaded-file marker; it does not override PowerShell execution policy or organisational restrictions. See the script's guide for execution-policy details.

## Using these scripts

Each script's folder includes its requirements, examples, outputs and limitations. Check these before running it. Generated reports can contain host and VM names; keep them out of public commits.

## Validation

The Hyper-V report has been checked with synthetic data in Windows PowerShell 5.1. Live Hyper-V validation is still outstanding. The included test script checks report generation and selected sizing classifications without requiring Hyper-V.
