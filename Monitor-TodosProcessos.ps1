#Requires -Version 5.1

[CmdletBinding()]
param(
    [int]    $IntervalSeconds      = 30,
    [int]    $FlushIntervalSeconds = 60,
    [string] $OutputDir            = "c:\temp",
    [double] $TopAlertCPU          = 50.0,
    [double] $TopAlertMemMB        = 1024.0,
    [int]    $TopConsoleRows       = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

# Garante que FlushInterval nao seja menor que IntervalSeconds
if ($FlushIntervalSeconds -lt $IntervalSeconds) {
    $FlushIntervalSeconds = $IntervalSeconds
}

# ---------------------------------------------
# CAMINHOS
# ---------------------------------------------
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$ts         = Get-Date -Format "yyyyMMdd_HHmmss"
$CsvRaw     = Join-Path $OutputDir "AllProc_Monitor_$ts.csv"
$CsvSummary = Join-Path $OutputDir "AllProc_Summary_$ts.csv"
$CsvAlertas = Join-Path $OutputDir "AllProc_Alertas_$ts.csv"
$StopFile   = Join-Path $OutputDir "STOP_MONITOR.txt"

if (Test-Path $StopFile) { Remove-Item $StopFile -Force }

# ---------------------------------------------
# ESTADO
# ---------------------------------------------
$script:Samples        = [System.Collections.Generic.List[PSObject]]::new()
$script:PendingFlush   = [System.Collections.Generic.List[PSObject]]::new()
$script:StartTime      = Get-Date
$script:LastCPUMap     = @{}
$script:LastFlushTime  = Get-Date
$script:TotalFlushed   = 0
$script:CsvHeaderWrote = $false

# ---------------------------------------------
# BANNER
# ---------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host "  Windows Monitor de Processos" -ForegroundColor Cyan
    Write-Host "  Servidor      : $($env:COMPUTERNAME)" -ForegroundColor Cyan
    Write-Host "  Usuario       : $($env:USERNAME)" -ForegroundColor Cyan
    Write-Host "  Coleta        : A cada $IntervalSeconds segundos..." -ForegroundColor Cyan
    Write-Host "  Flush CSV     : A cada $FlushIntervalSeconds segundos" -ForegroundColor Cyan
    Write-Host "  Alerta CPU    : >= $TopAlertCPU%  |  Alerta MEM: >= $TopAlertMemMB MB" -ForegroundColor Cyan
    Write-Host "  Top console   : $TopConsoleRows processos por ciclo (ordem CPU)" -ForegroundColor Cyan
    Write-Host "  CSV bruto     : $CsvRaw" -ForegroundColor Cyan
    Write-Host "  Iniciado      : $($script:StartTime.ToString('dd/MM/yyyy HH:mm:ss'))" -ForegroundColor Cyan
    Write-Host "===============================================================" -ForegroundColor Cyan
    Write-Host "  Para encerrar este script, rode em outra janela do PowerShell, execute:" -ForegroundColor Yellow
    Write-Host "  New-Item $StopFile -Force" -ForegroundColor White
    Write-Host "===============================================================`n" -ForegroundColor Cyan
}

# ---------------------------------------------
# CPU% por delta de TotalProcessorTime
# ---------------------------------------------
function Get-CPUPercent {
    param(
        [System.Diagnostics.Process] $Proc,
        [double]                     $DeltaSeconds
    )
    try {
        $current = $Proc.TotalProcessorTime.TotalSeconds
        $id      = $Proc.Id

        if ($script:LastCPUMap.ContainsKey($id) -and $DeltaSeconds -gt 0) {
            $delta = $current - $script:LastCPUMap[$id]
            $cores = [Environment]::ProcessorCount
            $pct   = [math]::Round(($delta / ($DeltaSeconds * $cores)) * 100, 2)
            $pct   = [math]::Max(0, [math]::Min($pct, 100))
        } else {
            $pct = 0.0
        }
        $script:LastCPUMap[$id] = $current
        return $pct
    }
    catch { return 0.0 }
}

# ---------------------------------------------
# I/O de todos os processos em uma unica query WMI
# ---------------------------------------------
function Get-AllProcessIO {
    $map = @{}
    try {
        foreach ($w in (Get-WmiObject Win32_PerfFormattedData_PerfProc_Process -ErrorAction SilentlyContinue)) {
            if ($w.IDProcess -gt 0) {
                $map[$w.IDProcess] = @{
                    IOReadKBs  = [math]::Round($w.IOReadBytesPersec  / 1KB, 2)
                    IOWriteKBs = [math]::Round($w.IOWriteBytesPersec / 1KB, 2)
                }
            }
        }
    } catch {}
    return $map
}

# ---------------------------------------------
# Handles de todos os processos em uma unica query WMI, isso pega os processos em execucao...
# ---------------------------------------------
function Get-AllProcessHandles {
    $map = @{}
    try {
        foreach ($w in (Get-WmiObject Win32_Process -ErrorAction SilentlyContinue)) {
            if ($w.ProcessId -gt 0) {
                $map[$w.ProcessId] = [int]$w.HandleCount
            }
        }
    } catch {}
    return $map
}

# ---------------------------------------------
# FLUSH INCREMENTAL - append no CSV bruto
# Grava apenas os registros pendentes desde o ultimo flush de 60s
# ---------------------------------------------
function Flush-ToCsv {
    param([bool]$Force = $false)

    $elapsed = ((Get-Date) - $script:LastFlushTime).TotalSeconds

    if (-not $Force -and $elapsed -lt $FlushIntervalSeconds) {
        return
    }

    if ($script:PendingFlush.Count -eq 0) {
        $script:LastFlushTime = Get-Date
        return
    }

    try {
        if (-not $script:CsvHeaderWrote) {
            # Primeiro flush: cria o arquivo com cabecalho
            $script:PendingFlush | Export-Csv -Path $CsvRaw -NoTypeInformation -Encoding UTF8 -Force
            $script:CsvHeaderWrote = $true
        } else {
            # Flushes seguintes: append sem cabecalho
            $script:PendingFlush |
                ConvertTo-Csv -NoTypeInformation |
                Select-Object -Skip 1 |
                Add-Content -Path $CsvRaw -Encoding UTF8
        }

        $flushed               = $script:PendingFlush.Count
        $script:TotalFlushed  += $flushed
        $script:LastFlushTime  = Get-Date

        $script:PendingFlush.Clear()

        $ts = (Get-Date).ToString("HH:mm:ss")
        Write-Host "  [FLUSH $ts] $flushed linhas gravadas em disco. Total acumulado: $($script:TotalFlushed) linhas -> $CsvRaw" `
                   -ForegroundColor DarkGreen
    }
    catch {
        Write-Host "  [ERRO FLUSH] Falha ao gravar CSV: $_" -ForegroundColor Red
    }
}

# ---------------------------------------------
# COLETA DE UM CICLO - TODOS OS PROCESSOS
# ---------------------------------------------
function Collect-Sample {
    param([datetime] $LastCollectTime)

    $now      = Get-Date
    $deltaSec = ($now - $LastCollectTime).TotalSeconds
    $rows     = [System.Collections.Generic.List[PSObject]]::new()

    $ioMap  = Get-AllProcessIO
    $hMap   = Get-AllProcessHandles
    $procs  = Get-Process -ErrorAction SilentlyContinue

    foreach ($proc in $procs) {
        $cpu     = Get-CPUPercent -Proc $proc -DeltaSeconds $deltaSec
        $memWS   = [math]::Round($proc.WorkingSet64        / 1MB, 2)
        $memPriv = [math]::Round($proc.PrivateMemorySize64 / 1MB, 2)

        $io      = if ($ioMap.ContainsKey($proc.Id)) { $ioMap[$proc.Id] } else { @{ IOReadKBs = 0.0; IOWriteKBs = 0.0 } }
        $handles = if ($hMap.ContainsKey($proc.Id))  { $hMap[$proc.Id]  } else { 0 }
        $status  = if ($proc.Responding -eq $false)  { "NOT_RESPONDING" } else { "OK" }

        $alertList = @()
        if ($cpu    -ge $TopAlertCPU)   { $alertList += "CPU_ALTO($cpu%)" }
        if ($memWS  -ge $TopAlertMemMB) { $alertList += "MEM_ALTA(${memWS}MB)" }
        if ($status -ne "OK")           { $alertList += "TRAVADO" }

        $row = [PSCustomObject]@{
            Timestamp        = $now.ToString("yyyy-MM-dd HH:mm:ss")
            Servidor         = $env:COMPUTERNAME
            ProcessName      = $proc.Name
            PID              = $proc.Id
            CPU_Pct          = $cpu
            MemWorkingSet_MB = $memWS
            MemPrivate_MB    = $memPriv
            Threads          = $proc.Threads.Count
            Handles          = $handles
            IORead_KBs       = $io.IOReadKBs
            IOWrite_KBs      = $io.IOWriteKBs
            Status           = $status
            Alerta           = ($alertList -join " | ")
        }

        $rows.Add($row)
        $script:Samples.Add($row)
        $script:PendingFlush.Add($row)
    }

    # Limpa PIDs encerrados do mapa de CPU
    $alivePIDs = $procs | Select-Object -ExpandProperty Id
    $deadPIDs  = @($script:LastCPUMap.Keys | Where-Object { $_ -notin $alivePIDs })
    foreach ($d in $deadPIDs) { $script:LastCPUMap.Remove($d) }

    return $rows
}

# ---------------------------------------------
# EXIBICAO AO VIVO - top N por CPU
# ---------------------------------------------
function Show-LiveTable {
    param(
        [System.Collections.Generic.List[PSObject]] $Rows,
        [int] $Cycle
    )
    $elapsed      = "{0:hh\:mm\:ss}" -f ((Get-Date) - $script:StartTime)
    $totalProcs   = $Rows.Count
    $alertsCount  = @($Rows | Where-Object { $_.Alerta -ne "" }).Count
    $nextFlush    = [math]::Max(0, [int]($FlushIntervalSeconds - ((Get-Date) - $script:LastFlushTime).TotalSeconds))

    Write-Host "`n[Ciclo #$Cycle | Processos: $totalProcs | Alertas: $alertsCount | Gravados: $($script:TotalFlushed) | Pendentes: $($script:PendingFlush.Count) | Prox.flush: ${nextFlush}s | Tempo: $elapsed]" `
               -ForegroundColor DarkCyan
    Write-Host "  Encerrar -> New-Item $StopFile -Force" -ForegroundColor DarkGray
    Write-Host ("  {0,-26} {1,-6} {2,7} {3,8} {4,8} {5,5} {6,6} {7,8} {8,8}  {9}" -f `
        "ProcessName", "PID", "CPU%", "WS(MB)", "Prv(MB)", "Thr", "Hdl", "R(KB/s)", "W(KB/s)", "Status") `
               -ForegroundColor DarkGray
    Write-Host "  $("-" * 115)" -ForegroundColor DarkGray

    $top = $Rows | Sort-Object CPU_Pct -Descending | Select-Object -First $TopConsoleRows

    foreach ($row in $top) {
        $color = "Green"
        if ($row.Alerta -ne "")                                         { $color = "Red"    }
        elseif ($row.CPU_Pct -ge 10 -or $row.MemWorkingSet_MB -ge 512) { $color = "Yellow" }

        $flag = if ($row.Alerta) { "[!] $($row.Alerta)" } else { "[OK]" }

        $line = "  {0,-26} {1,-6} {2,7} {3,8} {4,8} {5,5} {6,6} {7,8} {8,8}  {9}" -f
            ($row.ProcessName -replace "^(.{25}).*", '$1'),
            $row.PID,
            "$($row.CPU_Pct)%",
            $row.MemWorkingSet_MB,
            $row.MemPrivate_MB,
            $row.Threads,
            $row.Handles,
            $row.IORead_KBs,
            $row.IOWrite_KBs,
            $flag

        Write-Host $line -ForegroundColor $color
    }

    if ($totalProcs -gt $TopConsoleRows) {
        Write-Host "  ... e mais $($totalProcs - $TopConsoleRows) processos (todos gravados no CSV)" `
                   -ForegroundColor DarkGray
    }
}

# ---------------------------------------------
# EXPORTACAO FINAL - summary e alertas
# ---------------------------------------------
function Export-FinalReport {
    $endTime = Get-Date

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  Finalizando relatorios..." -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan

    # Flush forcado dos dados ainda pendentes
    Flush-ToCsv -Force $true

    if ($script:TotalFlushed -eq 0) {
        Write-Host "  [AVISO] Nenhum dado coletado." -ForegroundColor Red
        return
    }

    Write-Host "  [OK] Dados brutos  : $CsvRaw ($($script:TotalFlushed) linhas totais)" -ForegroundColor Green

    # CSV summary - le o CSV bruto para nao depender da lista em memoria
    try {
        $allData = Import-Csv -Path $CsvRaw -Encoding UTF8

        $summary = $allData |
            Group-Object ProcessName |
            ForEach-Object {
                $g = $_.Group
                [PSCustomObject]@{
                    ProcessName     = $_.Name
                    Amostras        = $g.Count
                    CPU_Max         = ($g | Measure-Object { [double]$_.CPU_Pct }          -Maximum).Maximum
                    CPU_Med         = [math]::Round(($g | Measure-Object { [double]$_.CPU_Pct } -Average).Average, 2)
                    MemWS_Max_MB    = ($g | Measure-Object { [double]$_.MemWorkingSet_MB } -Maximum).Maximum
                    MemWS_Med_MB    = [math]::Round(($g | Measure-Object { [double]$_.MemWorkingSet_MB } -Average).Average, 2)
                    MemPriv_Max_MB  = ($g | Measure-Object { [double]$_.MemPrivate_MB }   -Maximum).Maximum
                    IORead_Max_KBs  = ($g | Measure-Object { [double]$_.IORead_KBs }      -Maximum).Maximum
                    IOWrite_Max_KBs = ($g | Measure-Object { [double]$_.IOWrite_KBs }     -Maximum).Maximum
                    Handles_Max     = ($g | Measure-Object { [double]$_.Handles }         -Maximum).Maximum
                    Threads_Max     = ($g | Measure-Object { [double]$_.Threads }         -Maximum).Maximum
                    TotalAlertas    = ($g | Where-Object { $_.Alerta -ne "" }).Count
                    PrimeiroSample  = ($g | Sort-Object Timestamp | Select-Object -First 1).Timestamp
                    UltimoSample    = ($g | Sort-Object Timestamp | Select-Object -Last  1).Timestamp
                }
            } | Sort-Object { [double]$_.CPU_Max } -Descending

        $summary | Export-Csv -Path $CsvSummary -NoTypeInformation -Encoding UTF8 -Force
        Write-Host "  [OK] Resumo        : $CsvSummary ($($summary.Count) processos unicos)" -ForegroundColor Green

        Write-Host "`n  -- TOP 10 PROCESSOS POR CPU MAX ----------------------" -ForegroundColor Cyan
        $summary | Select-Object -First 10 | ForEach-Object {
            Write-Host ("  {0,-26} CPUmax:{1,6}%  CPUmed:{2,6}%  MEMmax:{3,8}MB  Alertas:{4}" -f
                $_.ProcessName, $_.CPU_Max, $_.CPU_Med, $_.MemWS_Max_MB, $_.TotalAlertas) -ForegroundColor White
        }
    } catch {
        Write-Host "  [ERRO] Falha ao gerar summary: $_" -ForegroundColor Red
    }

    # CSV alertas - le direto do CSV bruto
    try {
        $alerts = Import-Csv -Path $CsvRaw -Encoding UTF8 | Where-Object { $_.Alerta -ne "" }
        if ($alerts.Count -gt 0) {
            $alerts | Export-Csv -Path $CsvAlertas -NoTypeInformation -Encoding UTF8 -Force
            Write-Host "  [!]  Alertas       : $CsvAlertas ($($alerts.Count) eventos)" -ForegroundColor Yellow
        } else {
            Write-Host "  [OK] Sem alertas registrados no periodo." -ForegroundColor Green
        }
    } catch {
        Write-Host "  [ERRO] Falha ao gerar alertas: $_" -ForegroundColor Red
    }

    # Sumario final
    Write-Host "`n  -- SUMARIO FINAL -------------------------------------" -ForegroundColor Cyan
    Write-Host ("  Inicio     : {0}" -f $script:StartTime.ToString("dd/MM/yyyy HH:mm:ss")) -ForegroundColor White
    Write-Host ("  Fim        : {0}" -f $endTime.ToString("dd/MM/yyyy HH:mm:ss"))           -ForegroundColor White
    Write-Host ("  Duracao    : {0:hh\:mm\:ss}" -f ($endTime - $script:StartTime))          -ForegroundColor White
    Write-Host "  Linhas CSV : $($script:TotalFlushed)"                                     -ForegroundColor White
    Write-Host "  -----------------------------------------------------`n" -ForegroundColor Cyan

    if (Test-Path $StopFile) { Remove-Item $StopFile -Force }
}

# ---------------------------------------------
# LOOP PRINCIPAL
# ---------------------------------------------
Show-Banner

$lastCollectTime = (Get-Date).AddSeconds(-$IntervalSeconds)
$cycleNumber     = 0

Write-Host "  [INFO] Monitoramento iniciado. Coletando primeiro ciclo..." -ForegroundColor Gray

while (-not (Test-Path $StopFile)) {

    $cycleNumber++

    $rows = Collect-Sample -LastCollectTime $lastCollectTime
    Show-LiveTable -Rows $rows -Cycle $cycleNumber

    $lastCollectTime = Get-Date

    # Flush incremental se o intervalo foi atingido
    Flush-ToCsv

    # Aguarda intervalo de coleta verificando StopFile a cada 2 segundos
    $waited = 0
    while ($waited -lt $IntervalSeconds) {
        if (Test-Path $StopFile) { break }
        $sleep  = [math]::Min(2, $IntervalSeconds - $waited)
        Start-Sleep -Seconds $sleep
        $waited += $sleep
    }
}

Write-Host "`n  [INFO] Arquivo de parada detectado. Encerrando..." -ForegroundColor Yellow
Export-FinalReport