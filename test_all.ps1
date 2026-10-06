# Automated Test Suite for View-VpcFlowLogs.ps1 (Windows 11)
$ErrorActionPreference = 'Stop'

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Running Automated Test Suite for View-VpcFlowLogs.ps1" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$testCount = 0
$passCount = 0

function Run-Test([string]$name, [scriptblock]$action) {
    $global:testCount++
    Write-Host "`n[Test $global:testCount] $name" -ForegroundColor Yellow
    try {
        & $action
        Write-Host "[PASS] $name" -ForegroundColor Green
        $global:passCount++
    } catch {
        Write-Host "[FAIL] $name : $_" -ForegroundColor Red
        throw $_
    }
}

Run-Test "Single Parquet File Display" {
    $out = & .\View-VpcFlowLogs.ps1 -Path .\test_data\single_sample.parquet
    if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

Run-Test "Directory Recursive Traversal (test_data\s3)" {
    $out = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3
    if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

Run-Test "v2 Minimal Schema File (v2_only.parquet)" {
    $out = & .\View-VpcFlowLogs.ps1 -Path .\test_data\v2_only.parquet
    if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

Run-Test "Filter by Action (-Action REJECT)" {
    $records = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Action REJECT -PassThru
    if ($records.Count -ne 3) { throw "Expected 3 REJECT records, got $($records.Count)" }
    foreach ($r in $records) {
        if ($r.action -ne 'REJECT') { throw "Unexpected action: $($r.action)" }
    }
}

Run-Test "Filter by Protocol (-Protocol TCP)" {
    $records = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Protocol TCP -PassThru
    if ($records.Count -ne 6) { throw "Expected 6 TCP records, got $($records.Count)" }
}

Run-Test "Filter by IP (-IP 10.0.1.25)" {
    $records = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -IP 10.0.1.25 -PassThru
    if ($records.Count -lt 1) { throw "Expected records for IP 10.0.1.25" }
}

Run-Test "Summary Statistics Dashboard (-Stats)" {
    $out = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Stats
    if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
}

Run-Test "Output Formats (Csv, Json, List)" {
    $csv = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Format Csv -Limit 2
    if ($csv -notmatch '"start_time"') { throw "CSV header missing" }

    $json = & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Format Json -Limit 1
    $parsed = $json | ConvertFrom-Json
    if (-not $parsed.action) { throw "JSON parsing failed" }
}

Run-Test "Save to Output File (-OutFile)" {
    $tmpFile = ".\test_out_ps.txt"
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force }
    & .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -OutFile $tmpFile -Limit 2
    if (-not (Test-Path $tmpFile)) { throw "Output file was not created" }
    $content = Get-Content $tmpFile -Raw
    if ($content.Length -eq 0) { throw "Output file is empty" }
    Remove-Item $tmpFile -Force
}

Run-Test "Python Viewer Verification (vpc_flow_logs_viewer.py)" {
    $out = python vpc_flow_logs_viewer.py test_data\s3 --stats
    if ($LASTEXITCODE -ne 0) { throw "Python viewer failed" }
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " ALL $passCount / $testCount TESTS PASSED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
