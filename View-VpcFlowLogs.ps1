<#
.SYNOPSIS
    AWS VPC Flow Logs (Parquet) Viewer for Windows 11
.DESCRIPTION
    Reads AWS VPC Flow Logs saved in Apache Parquet format on Amazon S3.
    Supports single .parquet files or recursive directory scanning.
    Formats logs into human-readable representation (timestamps, protocol names,
    formatted bytes, TCP flags) and displays them on screen.
    Supports filtering, sorting, summary statistics, export formats (Table, Detail,
    CSV, JSON, GridView), and file output.
.PARAMETER Path
    Path to a .parquet file or a directory containing .parquet files.
.PARAMETER NoRecurse
    Do not scan subdirectories recursively when Path is a directory.
.PARAMETER Action
    Filter by action: 'ACCEPT', 'REJECT', or 'ALL' (default).
.PARAMETER Protocol
    Filter by protocol name (e.g. 'TCP', 'UDP', 'ICMP') or protocol number (e.g. 6, 17, 1).
.PARAMETER SrcAddr
    Filter by source IP address.
.PARAMETER DstAddr
    Filter by destination IP address.
.PARAMETER IP
    Filter by either source or destination IP address.
.PARAMETER SrcPort
    Filter by source port number.
.PARAMETER DstPort
    Filter by destination port number.
.PARAMETER Port
    Filter by either source or destination port number.
.PARAMETER Limit
    Limit the number of records displayed (0 for unlimited).
.PARAMETER Sort
    Column to sort by: 'time' (default), 'bytes', 'packets', 'srcaddr', 'dstaddr'.
.PARAMETER Order
    Sort order: 'ASC' (default) or 'DESC'.
.PARAMETER Format
    Display format: 'Table' (default), 'List' (Detail), 'Csv', 'Json', 'GridView'.
.PARAMETER OutFile
    Save output to the specified file in addition to displaying on screen.
.PARAMETER Stats
    Display summary statistics (total packets/bytes, accept/reject ratio, top talkers, ports).
.PARAMETER DetailedColumns
    Display all columns available in the Parquet files instead of standard flow view.
.PARAMETER PassThru
    Output PSObjects to the PowerShell pipeline for downstream processing.
.EXAMPLE
    .\View-VpcFlowLogs.ps1 -Path .\test_data\single_sample.parquet
.EXAMPLE
    .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Stats
.EXAMPLE
    .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Action REJECT -Format Table
.EXAMPLE
    .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Format GridView
#>

[CmdletBinding(DefaultParameterSetName = 'Display')]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
    [Alias('FullName', 'FilePath')]
    [string]$Path,

    [switch]$NoRecurse,

    [ValidateSet('ALL', 'ACCEPT', 'REJECT')]
    [string]$Action = 'ALL',

    [string]$Protocol,

    [string]$SrcAddr,
    [string]$DstAddr,
    [string]$IP,

    [int]$SrcPort = 0,
    [int]$DstPort = 0,
    [int]$Port = 0,

    [int]$Limit = 0,

    [ValidateSet('time', 'bytes', 'packets', 'srcaddr', 'dstaddr')]
    [string]$Sort = 'time',

    [ValidateSet('ASC', 'DESC')]
    [string]$Order = 'ASC',

    [ValidateSet('Table', 'List', 'Detail', 'Csv', 'Json', 'GridView', 'Raw')]
    [string]$Format = 'Table',

    [string]$OutFile,

    [switch]$Stats,

    [switch]$DetailedColumns,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-HumanBytes([double]$bytes) {
    if ($bytes -ge 1TB) { return ("{0:N2} TB" -f ($bytes / 1TB)) }
    if ($bytes -ge 1GB) { return ("{0:N2} GB" -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ("{0:N2} MB" -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ("{0:N2} KB" -f ($bytes / 1KB)) }
    return ("{0:N0} B" -f $bytes)
}

function Convert-ProtocolNumberToName([int]$proto) {
    switch ($proto) {
        1  { return 'ICMP' }
        2  { return 'IGMP' }
        6  { return 'TCP' }
        17 { return 'UDP' }
        41 { return 'IPv6' }
        47 { return 'GRE' }
        50 { return 'ESP' }
        51 { return 'AH' }
        58 { return 'ICMPv6' }
        89 { return 'OSPF' }
        default { return [string]$proto }
    }
}

function Convert-TcpFlagsToString([int]$flags) {
    if ($flags -eq 0) { return '-' }
    $names = [System.Collections.Generic.List[string]]::new()
    if ($flags -band 1)  { $names.Add('FIN') }
    if ($flags -band 2)  { $names.Add('SYN') }
    if ($flags -band 4)  { $names.Add('RST') }
    if ($flags -band 8)  { $names.Add('PSH') }
    if ($flags -band 16) { $names.Add('ACK') }
    if ($flags -band 32) { $names.Add('URG') }
    if ($names.Count -eq 0) { return [string]$flags }
    return ($names -join '-')
}

function Find-DuckDbEngine {
    # Check script-relative bin\duckdb.exe
    $scriptBin = Join-Path $PSScriptRoot 'bin\duckdb.exe'
    if (Test-Path $scriptBin) { return $scriptBin }

    # Check duckdb.exe next to script
    $adjacentBin = Join-Path $PSScriptRoot 'duckdb.exe'
    if (Test-Path $adjacentBin) { return $adjacentBin }

    # Check PATH
    $pathCmd = Get-Command duckdb.exe -ErrorAction SilentlyContinue
    if ($pathCmd -and (Test-Path $pathCmd.Source)) { return $pathCmd.Source }

    # Check local app data cache
    $cacheBin = Join-Path $env:LOCALAPPDATA 'vpc_flow_logs\duckdb.exe'
    if (Test-Path $cacheBin) { return $cacheBin }

    return $null
}

# --- Resolve target path and Parquet files ---
if (-not (Test-Path -Path $Path)) {
    Write-Error "Error: Specified path does not exist: '$Path'"
    exit 1
}

$resolvedPath = (Resolve-Path -Path $Path).Path
$isDir = (Get-Item -Path $resolvedPath) -is [System.IO.DirectoryInfo]

$fileCount = 0
$duckDbPathExpr = ""

if ($isDir) {
    $searchOpt = if ($NoRecurse) { [System.IO.SearchOption]::TopDirectoryOnly } else { [System.IO.SearchOption]::AllDirectories }
    $foundFiles = [System.IO.Directory]::GetFiles($resolvedPath, "*.parquet", $searchOpt)
    $fileCount = $foundFiles.Count
    if ($fileCount -eq 0) {
        Write-Error "Error: No .parquet files found in directory: '$resolvedPath'"
        exit 1
    }
    $cleanPath = $resolvedPath.Replace('\', '/')
    $duckDbPathExpr = if ($NoRecurse) { "'$cleanPath/*.parquet'" } else { "'$cleanPath/**/*.parquet'" }
} else {
    if ($resolvedPath -notmatch '\.parquet$') {
        Write-Warning "Warning: Specified file does not have .parquet extension: '$resolvedPath'"
    }
    $fileCount = 1
    $cleanPath = $resolvedPath.Replace('\', '/')
    $duckDbPathExpr = "'$cleanPath'"
}

# --- Locate DuckDB Engine ---
$duckDbExe = Find-DuckDbEngine

if (-not $duckDbExe) {
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    $viewerPy = Join-Path $PSScriptRoot 'vpc_flow_logs_viewer.py'
    if ($pythonCmd -and (Test-Path $viewerPy)) {
        $pyCheck = & $pythonCmd.Source -c "import duckdb" 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Verbose "DuckDB binary not found, delegating to Python engine..."
            $pyArgs = [System.Collections.Generic.List[string]]::new()
            $pyArgs.Add("`"$viewerPy`"")
            $pyArgs.Add("`"$resolvedPath`"")
            if ($Action -ne 'ALL') { $pyArgs.Add("-a"); $pyArgs.Add($Action) }
            if ($Protocol) { $pyArgs.Add("-p"); $pyArgs.Add($Protocol) }
            if ($SrcAddr) { $pyArgs.Add("-s"); $pyArgs.Add($SrcAddr) }
            if ($DstAddr) { $pyArgs.Add("-d"); $pyArgs.Add($DstAddr) }
            if ($IP) { $pyArgs.Add("-i"); $pyArgs.Add($IP) }
            if ($SrcPort -gt 0) { $pyArgs.Add("--srcport"); $pyArgs.Add($SrcPort) }
            if ($DstPort -gt 0) { $pyArgs.Add("--dstport"); $pyArgs.Add($DstPort) }
            if ($Port -gt 0) { $pyArgs.Add("--port"); $pyArgs.Add($Port) }
            if ($Limit -gt 0) { $pyArgs.Add("-l"); $pyArgs.Add($Limit) }
            if ($Sort) { $pyArgs.Add("--sort"); $pyArgs.Add($Sort.ToLower()) }
            if ($Order) { $pyArgs.Add("--order"); $pyArgs.Add($Order) }
            if ($Format -and $Format -ne 'Table') { $pyArgs.Add("-f"); $pyArgs.Add($Format.ToLower()) }
            if ($OutFile) { $pyArgs.Add("-o"); $pyArgs.Add("`"$OutFile`"") }
            if ($Stats) { $pyArgs.Add("--stats") }
            if ($DetailedColumns) { $pyArgs.Add("--all-columns") }
            if ($NoRecurse) { $pyArgs.Add("--no-recurse") }

            $argLine = $pyArgs -join " "
            Invoke-Expression "& `"$($pythonCmd.Source)`" $argLine"
            return
        }
    }

    Write-Error @"
[Error] DuckDB binary not found.
To resolve this:
  1. Ensure 'bin\duckdb.exe' exists in '$PSScriptRoot\bin\'
  2. Or add 'duckdb.exe' to your system PATH
  3. Or install DuckDB for Python: pip install duckdb
"@
    exit 1
}

# --- Inspect Parquet schema columns ---
$describeCmd = "& `"$duckDbExe`" -noheader -list -c `"SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet($duckDbPathExpr, union_by_name=true) LIMIT 1);`""
$availableColumns = Invoke-Expression $describeCmd
if ($LASTEXITCODE -ne 0 -or -not $availableColumns) {
    Write-Error "Failed to read Parquet metadata from: $Path"
    exit 1
}
$colList = @($availableColumns | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$hasTcpFlags = $colList -contains 'tcp_flags'
$hasFlowDir = $colList -contains 'flow_direction'
$hasVpcId = $colList -contains 'vpc_id'
$hasSubnetId = $colList -contains 'subnet_id'
$hasInstanceId = $colList -contains 'instance_id'

# --- Build SQL Filters ---
$whereClauses = [System.Collections.Generic.List[string]]::new()

if ($Action -and $Action -ne 'ALL') {
    $whereClauses.Add("action = '$Action'")
}

if ($Protocol) {
    if ($Protocol -match '^\d+$') {
        $whereClauses.Add("protocol = $Protocol")
    } else {
        $p = $Protocol.ToUpper()
        switch ($p) {
            'ICMP'   { $whereClauses.Add("protocol = 1") }
            'IGMP'   { $whereClauses.Add("protocol = 2") }
            'TCP'    { $whereClauses.Add("protocol = 6") }
            'UDP'    { $whereClauses.Add("protocol = 17") }
            'IPV6'   { $whereClauses.Add("protocol = 41") }
            'GRE'    { $whereClauses.Add("protocol = 47") }
            'ESP'    { $whereClauses.Add("protocol = 50") }
            'AH'     { $whereClauses.Add("protocol = 51") }
            'ICMPV6' { $whereClauses.Add("protocol = 58") }
            'OSPF'   { $whereClauses.Add("protocol = 89") }
            default  { $whereClauses.Add("protocol = '$Protocol'") }
        }
    }
}

if ($SrcAddr) { $whereClauses.Add("srcaddr = '$SrcAddr'") }
if ($DstAddr) { $whereClauses.Add("dstaddr = '$DstAddr'") }
if ($IP)      { $whereClauses.Add("(srcaddr = '$IP' OR dstaddr = '$IP')") }

if ($SrcPort -gt 0) { $whereClauses.Add("srcport = $SrcPort") }
if ($DstPort -gt 0) { $whereClauses.Add("dstport = $DstPort") }
if ($Port -gt 0)    { $whereClauses.Add("(srcport = $Port OR dstport = $Port)") }

$whereSql = ""
if ($whereClauses.Count -gt 0) {
    $whereSql = "WHERE " + ($whereClauses -join " AND ")
}

# --- Handle Summary Statistics Mode (-Stats) ---
if ($Stats) {
    $statsSql = @"
SELECT 
    count(*) AS total_flows,
    coalesce(sum(packets), 0) AS total_packets,
    coalesce(sum(bytes), 0) AS total_bytes,
    count(*) FILTER (WHERE action = 'ACCEPT') AS accept_count,
    count(*) FILTER (WHERE action = 'REJECT') AS reject_count,
    strftime(to_timestamp(min(start)), '%Y-%m-%d %H:%M:%S') AS min_time,
    strftime(to_timestamp(max(columns('^end$'))), '%Y-%m-%d %H:%M:%S') AS max_time
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql;
"@

    $statsJson = & $duckDbExe -json -c $statsSql | ConvertFrom-Json
    $st = $statsJson[0]

    $topTalkersSql = @"
SELECT 
    srcaddr AS source_ip,
    count(*) AS flows,
    sum(packets) AS packets,
    sum(bytes) AS bytes
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
GROUP BY srcaddr
ORDER BY bytes DESC
LIMIT 5;
"@
    $topTalkers = & $duckDbExe -json -c $topTalkersSql | ConvertFrom-Json

    $topDestSql = @"
SELECT 
    dstaddr AS destination_ip,
    count(*) AS flows,
    sum(packets) AS packets,
    sum(bytes) AS bytes
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
GROUP BY dstaddr
ORDER BY bytes DESC
LIMIT 5;
"@
    $topDest = & $duckDbExe -json -c $topDestSql | ConvertFrom-Json

    $topPortsSql = @"
SELECT 
    dstport AS port,
    count(*) AS flows,
    sum(bytes) AS bytes
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
GROUP BY dstport
ORDER BY flows DESC
LIMIT 5;
"@
    $topPorts = & $duckDbExe -json -c $topPortsSql | ConvertFrom-Json

    $protoSql = @"
SELECT 
    CASE protocol 
        WHEN 1 THEN 'ICMP' 
        WHEN 2 THEN 'IGMP' 
        WHEN 6 THEN 'TCP' 
        WHEN 17 THEN 'UDP' 
        WHEN 41 THEN 'IPv6' 
        WHEN 47 THEN 'GRE' 
        WHEN 50 THEN 'ESP' 
        WHEN 58 THEN 'ICMPv6' 
        ELSE CAST(protocol AS VARCHAR) 
    END AS proto,
    count(*) AS flows,
    sum(packets) AS packets,
    sum(bytes) AS bytes
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
GROUP BY protocol
ORDER BY flows DESC;
"@
    $protoStats = & $duckDbExe -json -c $protoSql | ConvertFrom-Json

    $sb = [System.Text.StringBuilder]::new()
    $sb.AppendLine("================================================================================") | Out-Null
    $sb.AppendLine(" AWS VPC Flow Logs - Summary Statistics") | Out-Null
    $sb.AppendLine("================================================================================") | Out-Null
    $sb.AppendLine(" Target Path      : $resolvedPath") | Out-Null
    $sb.AppendLine(" Parquet Files    : $fileCount file(s)") | Out-Null
    $sb.AppendLine(" Time Range       : $($st.min_time) ~ $($st.max_time)") | Out-Null
    $sb.AppendLine(" Total Flows      : {0:N0}" -f $st.total_flows) | Out-Null
    $sb.AppendLine(" Total Packets    : {0:N0}" -f $st.total_packets) | Out-Null
    $sb.AppendLine((" Total Bytes      : {0} ({1:N0} bytes)" -f @((Format-HumanBytes ([double]$st.total_bytes)), [double]$st.total_bytes))) | Out-Null

    $acceptPct = if ($st.total_flows -gt 0) { ([double]$st.accept_count / [double]$st.total_flows) * 100 } else { 0 }
    $rejectPct = if ($st.total_flows -gt 0) { ([double]$st.reject_count / [double]$st.total_flows) * 100 } else { 0 }
    $sb.AppendLine((" ACCEPT Flows     : {0:N0} ({1:N1}%)" -f @($st.accept_count, $acceptPct))) | Out-Null
    $sb.AppendLine((" REJECT Flows     : {0:N0} ({1:N1}%)" -f @($st.reject_count, $rejectPct))) | Out-Null
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- Top 5 Source IPs (by Bytes) ---") | Out-Null
    foreach ($row in $topTalkers) {
        $sb.AppendLine(("  {0,-18} {1,6} flows   {2,8:N0} packets   {3,12}" -f @($row.source_ip, $row.flows, $row.packets, (Format-HumanBytes ([double]$row.bytes))))) | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- Top 5 Destination IPs (by Bytes) ---") | Out-Null
    foreach ($row in $topDest) {
        $sb.AppendLine(("  {0,-18} {1,6} flows   {2,8:N0} packets   {3,12}" -f @($row.destination_ip, $row.flows, $row.packets, (Format-HumanBytes ([double]$row.bytes))))) | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- Top 5 Destination Ports (by Flows) ---") | Out-Null
    foreach ($row in $topPorts) {
        $sb.AppendLine(("  Port {0,-10} {1,6} flows   {2,12}" -f @($row.port, $row.flows, (Format-HumanBytes ([double]$row.bytes))))) | Out-Null
    }
    $sb.AppendLine("") | Out-Null

    $sb.AppendLine("--- Protocol Distribution ---") | Out-Null
    foreach ($row in $protoStats) {
        $sb.AppendLine(("  {0,-10} {1,6} flows   {2,8:N0} packets   {3,12}" -f @($row.proto, $row.flows, $row.packets, (Format-HumanBytes ([double]$row.bytes))))) | Out-Null
    }
    $sb.AppendLine("================================================================================") | Out-Null

    $statsText = $sb.ToString()
    Write-Host $statsText

    if ($OutFile) {
        Set-Content -Path $OutFile -Value $statsText -Encoding UTF8
        Write-Host "Summary statistics saved to: $OutFile" -ForegroundColor Cyan
    }
    return
}

# --- Build Data Query ---
$sortCol = switch ($Sort.ToLower()) {
    'bytes'    { 'bytes' }
    'packets'  { 'packets' }
    'srcaddr'  { 'srcaddr' }
    'dstaddr'  { 'dstaddr' }
    default    { 'start' }
}
$orderSql = "ORDER BY $sortCol $Order"
$limitSql = if ($Limit -gt 0) { "LIMIT $Limit" } else { "" }

if ($DetailedColumns) {
    $querySql = @"
SELECT * FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
$orderSql
$limitSql;
"@
} else {
    $selectParts = [System.Collections.Generic.List[string]]::new()
    $selectParts.Add("strftime(to_timestamp(start), '%Y-%m-%d %H:%M:%S') AS start_time")
    $selectParts.Add("strftime(to_timestamp(columns('^end$')), '%Y-%m-%d %H:%M:%S') AS end_time")
    $selectParts.Add("action")
    $selectParts.Add(@"
CASE protocol 
    WHEN 1 THEN 'ICMP' 
    WHEN 2 THEN 'IGMP' 
    WHEN 6 THEN 'TCP' 
    WHEN 17 THEN 'UDP' 
    WHEN 41 THEN 'IPv6' 
    WHEN 47 THEN 'GRE' 
    WHEN 50 THEN 'ESP' 
    WHEN 58 THEN 'ICMPv6' 
    ELSE CAST(protocol AS VARCHAR) 
END AS proto
"@)
    $selectParts.Add("srcaddr")
    $selectParts.Add("srcport")
    $selectParts.Add("dstaddr")
    $selectParts.Add("dstport")
    $selectParts.Add("packets")
    $selectParts.Add("bytes")

    if ($hasTcpFlags) {
        $selectParts.Add(@"
CASE tcp_flags 
    WHEN 1 THEN 'FIN' 
    WHEN 2 THEN 'SYN' 
    WHEN 4 THEN 'RST' 
    WHEN 16 THEN 'ACK' 
    WHEN 18 THEN 'SYN-ACK' 
    WHEN 0 THEN '-' 
    ELSE CAST(tcp_flags AS VARCHAR) 
END AS flags
"@)
    }

    if ($hasFlowDir) {
        $selectParts.Add("flow_direction AS dir")
    }

    $selectParts.Add("interface_id")
    $selectParts.Add("log_status")

    if ($hasVpcId) { $selectParts.Add("vpc_id") }
    if ($hasSubnetId) { $selectParts.Add("subnet_id") }
    if ($hasInstanceId) { $selectParts.Add("instance_id") }

    $selectSql = $selectParts -join ", `n    "

    $querySql = @"
SELECT 
    $selectSql
FROM read_parquet($duckDbPathExpr, union_by_name=true)
$whereSql
$orderSql
$limitSql;
"@
}

# --- Execute Query and Fetch JSON ---
$rawJson = & $duckDbExe -json -c $querySql
if ($LASTEXITCODE -ne 0) {
    Write-Error "Query execution failed."
    exit 1
}

if (-not $rawJson -or $rawJson.Trim() -eq '' -or $rawJson.Trim() -eq '[]') {
    Write-Host "No flow log records matched the criteria." -ForegroundColor Yellow
    return
}

$records = $rawJson | ConvertFrom-Json

# Enrich records with human-friendly values for display
foreach ($rec in $records) {
    if ($rec.PSObject.Properties['bytes']) {
        $humanSize = Format-HumanBytes ([double]$rec.bytes)
        Add-Member -InputObject $rec -NotePropertyName 'bytes_human' -NotePropertyValue $humanSize -Force
    }
    if ($rec.PSObject.Properties['srcaddr'] -and $rec.PSObject.Properties['srcport']) {
        Add-Member -InputObject $rec -NotePropertyName 'source' -NotePropertyValue ("{0}:{1}" -f $rec.srcaddr, $rec.srcport) -Force
    }
    if ($rec.PSObject.Properties['dstaddr'] -and $rec.PSObject.Properties['dstport']) {
        Add-Member -InputObject $rec -NotePropertyName 'destination' -NotePropertyValue ("{0}:{1}" -f $rec.dstaddr, $rec.dstport) -Force
    }
}

# --- Output Formatting ---
$outputString = ""

switch ($Format) {
    'Table' {
        Write-Host "Processed $fileCount Parquet file(s). Displaying $($records.Count) record(s):`n" -ForegroundColor DarkCyan
        if (-not $DetailedColumns) {
            $tableCols = @(
                @{ Label = 'Start Time'; Expression = { $_.start_time }; Width = 19 },
                @{ Label = 'End Time'; Expression = { $_.end_time }; Width = 19 },
                @{ Label = 'Action'; Expression = { $_.action }; Width = 8 },
                @{ Label = 'Proto'; Expression = { $_.proto }; Width = 6 },
                @{ Label = 'Source'; Expression = { $_.source }; Width = 21 },
                @{ Label = 'Destination'; Expression = { $_.destination }; Width = 21 },
                @{ Label = 'Packets'; Expression = { "{0:N0}" -f $_.packets }; Width = 9 },
                @{ Label = 'Bytes'; Expression = { $_.bytes_human }; Width = 11 }
            )
            if ($hasTcpFlags) { $tableCols += @{ Label = 'Flags'; Expression = { $_.flags }; Width = 8 } }
            if ($hasFlowDir)  { $tableCols += @{ Label = 'Dir'; Expression = { $_.dir }; Width = 8 } }
            $tableCols += @{ Label = 'Interface'; Expression = { $_.interface_id }; Width = 22 }
            $tableCols += @{ Label = 'Status'; Expression = { $_.log_status }; Width = 7 }

            $outputString = ($records | Format-Table -Property $tableCols | Out-String -Width 4096)
        } else {
            $outputString = ($records | Format-Table -AutoSize | Out-String -Width 4096)
        }
        Write-Host $outputString
    }

    { $_ -in 'List', 'Detail' } {
        Write-Host "Processed $fileCount Parquet file(s). Displaying $($records.Count) record(s) in Detail view:`n" -ForegroundColor DarkCyan
        $outputString = ($records | Format-List | Out-String)
        Write-Host $outputString
    }

    'Csv' {
        $outputString = ($records | ConvertTo-Csv -NoTypeInformation | Out-String)
        Write-Output $outputString
    }

    'Json' {
        $outputString = ($records | ConvertTo-Json -Depth 5)
        Write-Output $outputString
    }

    'GridView' {
        Write-Host "Opening interactive GridView with $($records.Count) record(s)..." -ForegroundColor Cyan
        $records | Out-GridView -Title "AWS VPC Flow Logs ($fileCount files)"
    }

    'Raw' {
        $outputString = $rawJson
        Write-Output $outputString
    }
}

# --- Save to file if requested ---
if ($OutFile -and $outputString) {
    Set-Content -Path $OutFile -Value $outputString -Encoding UTF8
    Write-Host "`nOutput successfully saved to: $OutFile" -ForegroundColor Green
}

# --- PassThru for PowerShell Pipeline ---
if ($PassThru) {
    Write-Output $records
}
