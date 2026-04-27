# mok-enrollement

Script for MOK enrollment on VMware guests.

## Quality checks

## GitHub Actions

CI runs automatically on GitHub for every pull request and on pushes to `main`, executing:

- Pester tests (`Invoke-Pester -Path ./tests -CI`)
- PSScriptAnalyzer checks (`Invoke-ScriptAnalyzer -Path ./Invoke-MokDerEnrollment.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse`)

### Run unit tests (Pester)

```powershell
Invoke-Pester -Path ./tests
```

### Run static analysis (PSScriptAnalyzer)

```powershell
Invoke-ScriptAnalyzer -Path ./Invoke-MokDerEnrollment.ps1 -Settings ./PSScriptAnalyzerSettings.psd1 -Recurse
```
