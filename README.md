# mok-enrollement

Script for MOK enrollment on VMware guests.

## Quality checks

### Run unit tests (Pester)

```powershell
Invoke-Pester -Path ./tests
```

### Run static analysis (PSScriptAnalyzer)

```powershell
Invoke-ScriptAnalyzer -Path ./Invoke-MokDerEnrollment.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse
```
