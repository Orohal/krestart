#requires -Version 5.1

$script:TestFailures = 0

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Condition) {
        Write-Host "PASS  $Name" -ForegroundColor Green
    } else {
        Write-Host "FAIL  $Name" -ForegroundColor Red
        $script:TestFailures++
    }
}

function Assert-Complete {
    if ($script:TestFailures -gt 0) {
        throw "$($script:TestFailures) Test(s) fehlgeschlagen."
    }

    Write-Host 'Alle Tests erfolgreich.' -ForegroundColor Green
}

function Send-MagicPacket {
    [CmdletBinding()]
    param(
        [int]$Port = 9,
        [int]$Count = 1
    )

    $mac = [byte[]](0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF)
    $packet = [byte[]]::new(102)
    for ($i = 0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
    for ($i = 0; $i -lt 16; $i++) { [Array]::Copy($mac, 0, $packet, 6 + $i * 6, 6) }

    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        for ($i = 0; $i -lt $Count; $i++) {
            $null = $udp.Send($packet, $packet.Length, '127.0.0.1', $Port)
        }
    } finally {
        $udp.Dispose()
    }
}

function Build-FakeKodi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$OutputDirectory
    )

    $project = Join-Path $RepositoryRoot 'tests\FakeKodi\FakeKodi.csproj'
    if (-not (Test-Path $project)) {
        throw "FakeKodi-Projekt nicht gefunden: $project"
    }

    $output = & dotnet build $project -c Release -o $OutputDirectory --nologo -v q 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "FakeKodi konnte nicht gebaut werden:`n$($output -join [Environment]::NewLine)"
    }

    $exe = Join-Path $OutputDirectory 'FakeKodi.exe'
    if (-not (Test-Path $exe)) {
        throw "FakeKodi.exe wurde nicht erzeugt: $exe"
    }

    return $exe
}

function New-TestWorkspace {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('KodiWolListenerTests-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Wait-Until {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutMs = 5000,
        [int]$IntervalMs = 100
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    do {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds $IntervalMs
    } while ([DateTime]::UtcNow -lt $deadline)

    return [bool](& $Condition)
}
