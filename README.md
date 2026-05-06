# mok-enrollement

Script for MOK enrollment on VMware guests, with an additional Hyper-V variant.

## Quality checks

## GitHub Actions

CI runs automatically on GitHub for every pull request and on pushes to `main`, executing:

- Pester tests (`Invoke-Pester -Path ./tests -CI`)
- PSScriptAnalyzer checks on both scripts and tests (run once per path to avoid `-Path` binding issues on some agents):
  `@('./Invoke-MokDerEnrollment.ps1','./Invoke-MokDerEnrollment-HyperV.ps1','./tests') | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse -EnableExit }`

### Run unit tests (Pester)

```powershell
Invoke-Pester -Path ./tests
```

### Run static analysis (PSScriptAnalyzer)

```powershell
@('./Invoke-MokDerEnrollment.ps1','./Invoke-MokDerEnrollment-HyperV.ps1','./tests') | ForEach-Object { Invoke-ScriptAnalyzer -Path $_ -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse -EnableExit }
```


## Hyper-V variant

A dedicated Hyper-V script is available: `Invoke-MokDerEnrollment-HyperV.ps1`.

It follows the same high-level workflow (copy `.der`, run `mokutil --import`, reboot), but uses:
- SSH/SCP for guest operations
- Hyper-V cmdlets for VM reboot
- optional Hyper-V keyboard injection for menu navigation

Example:

```powershell
./Invoke-MokDerEnrollment-HyperV.ps1 `
  -VMName rhel9-secureboot `
  -DerFolder ./certs `
  -GuestAddress 192.168.122.50 `
  -GuestUser root `
  -MokAutomationMode ManualMenu
```
