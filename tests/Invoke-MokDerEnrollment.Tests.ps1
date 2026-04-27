Set-StrictMode -Version Latest

BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'Invoke-MokDerEnrollment.ps1'
    . $scriptPath -vCenter 'unit-test' -DerFolder 'unit-test'
}

Describe 'ConvertTo-BashLiteral' {
    It 'quotes and escapes single quotes' {
        $value = ConvertTo-BashLiteral -Text "abc'def"
        $value | Should -Be "'abc'\''def'"
    }
}

Describe 'Expand-Template' {
    It 'replaces all template placeholders' {
        $expanded = Expand-Template -Template 'hello __NAME__, id=__ID__' -Values @{ NAME = 'mok'; ID = 42 }
        $expanded | Should -Be 'hello mok, id=42'
    }
}

Describe 'Get-DerFiles' {
    It 'returns sorted .der files only' {
        $tmp = Join-Path $TestDrive 'der-files'
        New-Item -Path $tmp -ItemType Directory | Out-Null
        New-Item -Path (Join-Path $tmp 'b.der') -ItemType File | Out-Null
        New-Item -Path (Join-Path $tmp 'a.der') -ItemType File | Out-Null
        New-Item -Path (Join-Path $tmp 'ignore.txt') -ItemType File | Out-Null

        $files = Get-DerFiles -Folder $tmp
        $files.Count | Should -Be 2
        [System.IO.Path]::GetFileName($files[0]) | Should -Be 'a.der'
        [System.IO.Path]::GetFileName($files[1]) | Should -Be 'b.der'
    }

    It 'throws when no der file exists' {
        $tmp = Join-Path $TestDrive 'empty-der'
        New-Item -Path $tmp -ItemType Directory | Out-Null

        { Get-DerFiles -Folder $tmp } | Should -Throw 'No .der files found*'
    }
}

Describe 'Import-VMList' {
    It 'parses plain text VM list and removes comments' {
        $path = Join-Path $TestDrive 'vms.txt'
        @(
            '# comment'
            ' vm-alpha '
            ''
            'vm-beta'
        ) | Set-Content -Path $path

        $vms = Import-VMList -Path $path
        $vms.VMName | Should -Be @('vm-alpha', 'vm-beta')
    }

    It 'parses csv VM list with VMName header' {
        $path = Join-Path $TestDrive 'vms.csv'
        @(
            'VMName;Other'
            'vm-01;ignored'
            'vm-02;ignored'
        ) | Set-Content -Path $path

        $vms = Import-VMList -Path $path -Delimiter ';'
        $vms.VMName | Should -Be @('vm-01', 'vm-02')
    }
}

Describe 'Get-PrepareScript' {
    It 'does not use sudo for root mode' {
        $scriptText = Get-PrepareScript -IsRoot $true -GuestDestinationQ "'/tmp/mok'" -SudoPasswordB64 'unused'
        $scriptText | Should -Not -Match 'sudo -S'
        $scriptText | Should -Match "DEST='/tmp/mok'"
    }

    It 'uses sudo flow in non-root mode' {
        $scriptText = Get-PrepareScript -IsRoot $false -GuestDestinationQ "'/tmp/mok'" -SudoPasswordB64 'YWJj'
        $scriptText | Should -Match 'sudo -S'
        $scriptText | Should -Match 'YWJj'
    }
}
