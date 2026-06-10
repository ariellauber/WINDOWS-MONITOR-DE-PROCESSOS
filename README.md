### WINDOWS SERVER/ENDPOINT - COLETA INFORMAÇÕES DE PROCESSOS EM EXECUÇÃO

> **Plataforma:** Windows Server / Windows Desktop (7, 8, 8.1, 10, 11)
> **Requisito:** PowerShell 5.1 ou superior  
> **Privilegio:** Administrador  
> **Saida padrao:** `C:\temp\` (configuravel no script)

---

## Sumario

1. [Visao Geral](#1-visao-geral)
2. [Como Funciona](#2-como-funciona)
3. [Parametros](#3-parametros)
4. [Execucao](#4-execucao)
5. [Arquivos de Saida](#5-arquivos-de-saida)
6. [Leitura do Console ao Vivo](#6-leitura-do-console-ao-vivo)
7. [Consideracoes de Uso](#7-consideracoes-de-uso)
8. [Troubleshooting](#8-troubleshooting)
9. [Referencia Rapida de Comandos](#9-referencia-rapida-de-comandos)

---

## 1. Visao Geral

O script `Monitor-TodosProcessos.ps1` realiza o monitoramento continuo de todos os processos em execucao no Windows, coletando métricas de desempenho em intervalos regulares e persistindo os dados em arquivos CSV de forma incremental - garantindo que nenhuma informacao seja perdida mesmo em cenarios de instabilidade do servidor.

**Casos de uso tipicos:**

- Diagnostico de lentidao em servidores de ERP e aplicacoes criticas
- Identificacao de processos com consumo anormal de CPU ou memoria
- Investigacao do impacto de agentes de seguranca (ex: Trend Micro, CrowdStrike) sobre a carga do sistema
- Coleta de evidencias para analise de incidentes de performance
- Monitoramento de longa duracao em servidores com acesso remoto instavel

> **Nota:** O script nao requer instalacao de modulos externos. Utiliza apenas cmdlets nativos do PowerShell e consultas WMI disponiveis em qualquer Windows Server 2012 R2 ou superior.

---

## 2. Como Funciona

### 2.1 Ciclo de Coleta

A cada intervalo definido pelo parametro `-IntervalSeconds`, o script executa um ciclo completo:

1. Realiza duas consultas WMI em **batch** - uma para I/O de disco e outra para contagem de handles - evitando chamadas individuais por processo
2. Enumera todos os processos ativos via `Get-Process`
3. Calcula o **CPU%** de cada processo usando o delta de `TotalProcessorTime` entre dois ciclos consecutivos, normalizado pelo numero de nucleos logicos do servidor
4. Consolida as metricas em um objeto estruturado por processo
5. Avalia os thresholds de alerta configurados

### 2.2 Flush Incremental para Disco

Os dados coletados sao mantidos em duas listas em memoria:

- **`Samples`** - acumula todos os registros do inicio ao fim (usada para o relatorio final)
- **`PendingFlush`** - acumula apenas os registros ainda nao gravados em disco

A cada `FlushIntervalSeconds` segundos, a funcao `Flush-ToCsv` grava os registros pendentes no CSV usando **modo append**, sem reescrever o arquivo inteiro. O primeiro flush cria o arquivo com cabecalho; os seguintes apenas adicionam linhas.

> **Tolerancia a falhas:** Mesmo que o servidor trave ou fique inacessivel antes do encerramento formal do script, os dados de todos os ciclos anteriores ao ultimo flush ja estao persistidos em disco e podem ser recuperados.

### 2.3 Mecanismo de Encerramento

O script monitora continuamente a existencia de um **arquivo sentinela** (`STOP_MONITOR.txt`) no diretorio de saida. Quando o arquivo e detectado, o loop encerra de forma controlada e o relatorio final e gerado.

Este mecanismo foi adotado porque metodos tradicionais (`Ctrl+C`, `CancelKeyPress`, `Register-EngineEvent`) se comportam de forma inconsistente dependendo do host do PowerShell utilizado (Windows Terminal, conhost.exe, sessoes SSH, ISE), podendo encerrar o processo antes da gravacao dos arquivos CSV.

---

## 3. Parametros

| Parametro | Tipo | Padrao | Descricao |
|---|---|---|---|
| `-IntervalSeconds` | Int | `30` | Intervalo em segundos entre cada ciclo de coleta de metricas |
| `-FlushIntervalSeconds` | Int | `60` | Intervalo em segundos entre cada gravacao incremental no CSV. Nunca sera menor que `IntervalSeconds` |
| `-OutputDir` | String | `C:\Temp` | Diretorio onde os arquivos CSV serao gravados. Criado automaticamente se nao existir |
| `-TopAlertCPU` | Double | `50.0` | Percentual de CPU acima do qual o registro e marcado como `ALERTA` no campo `Alerta` do CSV |
| `-TopAlertMemMB` | Double | `1024.0` | Memoria WorkingSet em MB acima do qual o registro e marcado como `ALERTA` no campo `Alerta` do CSV |
| `-TopConsoleRows` | Int | `10` | Quantidade de processos exibidos no console por ciclo, ordenados por CPU% decrescente. **Nao afeta o CSV** |

> **Nota sobre FlushIntervalSeconds:** Se um valor menor que `IntervalSeconds` for informado, o script ajusta automaticamente `FlushIntervalSeconds` para ser igual a `IntervalSeconds`, garantindo que pelo menos um ciclo seja gravado por flush.

---

## 4. Execucao

### 4.1 Preparacao

Abrir o PowerShell como **Administrador** e, se necessario, liberar a politica de execucao de scripts:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

### 4.2 Exemplos de Uso

**Execucao com parametros padrao**
```powershell
.\Monitor-TodosProcessos.ps1
```
Coleta a cada 30s, flush a cada 60s, alertas em CPU >= 50% ou Memoria >= 1024 MB, exibe 10 processos no console, salva em `C:\Temp\`.

---

**Intervalo curto para captura de picos**
```powershell
.\Monitor-TodosProcessos.ps1 -IntervalSeconds 15 -FlushIntervalSeconds 30
```
Indicado para investigacoes ativas durante incidentes. Gera mais dados mas captura picos de curta duracao.

---

**Thresholds de alerta customizados**
```powershell
.\Monitor-TodosProcessos.ps1 -TopAlertCPU 20 -TopAlertMemMB 512
```
Indicado para ambientes onde qualquer processo acima de 20% de CPU ou 512 MB ja e considerado anomalo.

---

**Diretorio e visualizacao customizados**
```powershell
.\Monitor-TodosProcessos.ps1 -OutputDir "C:\Logs\Monitor" -TopConsoleRows 30
```

---

**Combinacao completa de parametros**
```powershell
.\Monitor-TodosProcessos.ps1 `
    -IntervalSeconds 15 `
    -FlushIntervalSeconds 30 `
    -OutputDir "C:\Logs\Monitor" `
    -TopAlertCPU 20 `
    -TopAlertMemMB 512 `
    -TopConsoleRows 25
```

### 4.3 Como Encerrar o Script

O script nao responde a `Ctrl+C` de forma confiavel em todos os ambientes. O metodo correto e criar o arquivo sentinela **em uma segunda janela do PowerShell**:

```powershell
# Em outro terminal PowerShell (ou via RDP, SSH, PsExec, etc.)
New-Item C:\Temp\STOP_MONITOR.txt -Force
```

O script detecta o arquivo em ate **2 segundos**, executa um flush final dos dados pendentes, gera os arquivos `_Summary` e `_Alertas`, exibe o sumario no console e encerra.

> **Recuperacao em caso de travamento:** Se o servidor travar antes do encerramento formal, os arquivos CSV brutos ja estarao em disco com todos os dados gravados ate o ultimo flush automatico. O arquivo Summary e gerado apenas no encerramento normal, mas o CSV bruto pode ser analisado diretamente.

---

## 5. Arquivos de Saida

Todos os arquivos sao gerados no diretorio definido por `-OutputDir` com **timestamp no nome**, permitindo multiplas execucoes sem sobrescrita.

### 5.1 `AllProc_Monitor_<timestamp>.csv` - Dados Brutos

Arquivo principal, gravado incrementalmente a cada `FlushIntervalSeconds` segundos. Contem **uma linha por processo por ciclo** de coleta.

| Coluna | Tipo | Descricao |
|---|---|---|
| `Timestamp` | DateTime | Data e hora da coleta no formato `yyyy-MM-dd HH:mm:ss` |
| `Servidor` | String | Nome do computador (`COMPUTERNAME`) |
| `ProcessName` | String | Nome do processo sem extensao |
| `PID` | Int | Identificador unico do processo no sistema operacional |
| `CPU_Pct` | Double | Percentual de CPU consumido no intervalo entre os dois ultimos ciclos, normalizado pelo numero de nucleos logicos. Varia de `0.00` a `100.00` |
| `MemWorkingSet_MB` | Double | Memoria fisica atualmente em uso pelo processo em MB (Working Set) |
| `MemPrivate_MB` | Double | Memoria privada alocada exclusivamente pelo processo em MB (nao compartilhada) |
| `Threads` | Int | Numero de threads ativos no processo |
| `Handles` | Int | Total de handles abertos (arquivos, registros, sockets, pipes) |
| `IORead_KBs` | Double | Taxa de leitura de disco em KB/s no momento da coleta |
| `IOWrite_KBs` | Double | Taxa de escrita em disco em KB/s no momento da coleta |
| `Status` | String | `OK` se o processo esta respondendo, `NOT_RESPONDING` se travado |
| `Alerta` | String | Vazio se normal. Preenchido com o(s) motivo(s): `CPU_ALTO(X%)`, `MEM_ALTA(XMB)`, `TRAVADO` |

### 5.2 `AllProc_Summary_<timestamp>.csv` - Resumo Estatistico

Gerado apenas no **encerramento normal**. Agrupa os dados brutos por nome de processo e calcula estatisticas para todo o periodo de monitoramento.

| Coluna | Descricao |
|---|---|
| `ProcessName` | Nome do processo |
| `Amostras` | Total de registros coletados para este processo |
| `CPU_Max` | Maior valor de CPU% registrado em qualquer ciclo |
| `CPU_Med` | Media de CPU% ao longo de todo o periodo |
| `MemWS_Max_MB` | Pico maximo de memoria WorkingSet registrado |
| `MemWS_Med_MB` | Media de memoria WorkingSet ao longo do periodo |
| `MemPriv_Max_MB` | Pico maximo de memoria privada registrado |
| `IORead_Max_KBs` | Maior taxa de leitura de disco registrada |
| `IOWrite_Max_KBs` | Maior taxa de escrita em disco registrada |
| `Handles_Max` | Maior numero de handles abertos registrado |
| `Threads_Max` | Maior numero de threads registrado |
| `TotalAlertas` | Quantidade de ciclos em que o processo disparou algum alerta |
| `PrimeiroSample` | Timestamp da primeira coleta do processo |
| `UltimoSample` | Timestamp da ultima coleta do processo |

### 5.3 `AllProc_Alertas_<timestamp>.csv` - Eventos de Alerta

Gerado apenas no **encerramento normal**. Contem exclusivamente os registros do CSV bruto onde o campo `Alerta` esta preenchido. Facilita a analise focada nos momentos de anomalia sem precisar filtrar manualmente o CSV bruto.

**Valores possiveis no campo `Alerta`:**

| Valor | Condicao |
|---|---|
| `CPU_ALTO(X%)` | CPU% igual ou superior ao threshold `-TopAlertCPU` |
| `MEM_ALTA(XMB)` | Memoria WorkingSet igual ou superior ao threshold `-TopAlertMemMB` |
| `TRAVADO` | `Process.Responding` retornou `false` |
| `CPU_ALTO(X%) \| MEM_ALTA(XMB)` | Multiplos alertas no mesmo ciclo, separados por ` \| ` |

---

## 6. Leitura do Console ao Vivo

### 6.1 Linha de Status

A cada ciclo, o console exibe uma linha de status no topo da tabela:

```
[Ciclo #4 | Processos: 187 | Alertas: 2 | Gravados: 561 | Pendentes: 187 | Prox.flush: 23s | Tempo: 00:02:00]
```

| Campo | Significado |
|---|---|
| `Ciclo #N` | Numero sequencial do ciclo de coleta desde o inicio |
| `Processos` | Total de processos encontrados neste ciclo |
| `Alertas` | Quantos processos dispararam alerta neste ciclo |
| `Gravados` | Total de linhas ja persistidas em disco no CSV bruto |
| `Pendentes` | Linhas coletadas que ainda nao foram gravadas em disco |
| `Prox.flush` | Segundos restantes ate o proximo flush automatico |
| `Tempo` | Tempo total decorrido desde o inicio do monitoramento |

### 6.2 Codigo de Cores

| Cor | Condicao |
|---|---|
| 🟢 Verde | Processo normal, dentro dos thresholds configurados |
| 🟡 Amarelo | CPU >= 10% ou WorkingSet >= 512 MB - atencao recomendada |
| 🔴 Vermelho | Alerta disparado - processo ultrapassou `-TopAlertCPU` ou `-TopAlertMemMB`, ou esta sem resposta |

> **Observacao:** Os thresholds de cor amarela (CPU >= 10% e MEM >= 512 MB) sao fixos no codigo e servem como aviso precoce, enquanto os thresholds de alerta vermelho sao controlados pelos parametros `-TopAlertCPU` e `-TopAlertMemMB`.

---

## 7. Consideracoes de Uso

### 7.1 Impacto de Performance

O script foi projetado para minimizar seu proprio impacto sobre o sistema monitorado:

- Consultas WMI executadas em **batch** - uma unica chamada por ciclo para I/O e uma para Handles
- Calculo de CPU por delta de `TotalProcessorTime` e leve, sem necessidade de `Get-Counter`
- Flush incremental grava apenas os registros pendentes, sem reescrever o arquivo inteiro
- PIDs de processos encerrados sao **removidos automaticamente** do mapa de CPU a cada ciclo, evitando vazamento de memoria em execucoes longas

### 7.2 Estimativa de Tamanho do CSV

| Processos | Intervalo | Duracao | Linhas aproximadas |
|---|---|---|---|
| 150 | 30s | 8 horas | ~144.000 linhas |
| 200 | 30s | 8 horas | ~192.000 linhas |
| 200 | 15s | 8 horas | ~384.000 linhas |
| 200 | 60s | 24 horas | ~288.000 linhas |

Para coletas de longa duracao (mais de 4 horas), recomenda-se usar `-IntervalSeconds` entre `30` e `60`.

### 7.3 Permissoes Necessarias

- **Administrador local** - recomendado para acesso completo a todos os processos e WMI
- **Sem privilegio de administrador** - o script funcionara, mas alguns processos do sistema (`LSASS`, `CSRSS`, etc.) podem retornar valores zero nas metricas de I/O e Handles por restricao de acesso

### 7.4 Compatibilidade

- Windows Server 2012 R2, 2016, 2019, 2022
- Windows 10, Windows 11
- PowerShell 5.1 (nativo) e PowerShell 7.x
- Compativel com execucao via RDP, WinRM, SSH e PsExec

---

## 8. Troubleshooting

| Problema | Solucao |
|---|---|
| Script nao inicia: erro de politica de execucao | Executar: `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` |
| CSV nao e gerado ao encerrar | Usar o metodo do arquivo sentinela: `New-Item C:\Temp\STOP_MONITOR.txt -Force` em outro PowerShell. Nao usar `Ctrl+C` |
| Colunas `IORead_KBs` e `IOWrite_KBs` sempre zeradas | Executar o script com privilegio de Administrador. A WMI `Win32_PerfFormattedData` pode retornar zero para usuarios sem privilegio |
| `CPU_Pct` zerado no primeiro ciclo | Comportamento esperado. O calculo de CPU requer dois snapshots consecutivos. O primeiro ciclo sempre retorna 0% pois nao ha historico anterior |
| Script consome muita CPU no proprio servidor | Aumentar `-IntervalSeconds` para `60` ou `120`. A consulta WMI de I/O (`Win32_PerfFormattedData`) e a mais custosa em servidores com muitos processos |
| Arquivo CSV corrompido ou incompleto | O arquivo bruto pode ser aberto mesmo durante a execucao. Se o servidor travou, o arquivo contem todos os dados ate o ultimo flush automatico |
| Erro de acesso negado ao criar `C:\Temp` | Usar `-OutputDir` apontando para um diretorio com permissao de escrita, ex: `-OutputDir "$env:USERPROFILE\Documents"` |

---

## 9. Referencia Rapida de Comandos

**Iniciar monitoramento com parametros padrao**
```powershell
.\Monitor-TodosProcessos.ps1
```

**Iniciar com intervalo e flush customizados**
```powershell
.\Monitor-TodosProcessos.ps1 -IntervalSeconds 15 -FlushIntervalSeconds 30
```

**Encerrar o script (em outro PowerShell)**
```powershell
New-Item C:\Temp\STOP_MONITOR.txt -Force
```

**Importar e analisar o CSV bruto no PowerShell**
```powershell
# Importar o CSV
$data = Import-Csv "C:\Temp\AllProc_Monitor_*.csv"

# Top 10 processos por CPU media
$data | Group-Object ProcessName | ForEach-Object {
    $g = $_.Group
    [PSCustomObject]@{
        Nome   = $_.Name
        CPUMed = [math]::Round(($g | Measure-Object { [double]$_.CPU_Pct } -Average).Average, 2)
        CPUMax = ($g | Measure-Object { [double]$_.CPU_Pct } -Maximum).Maximum
    }
} | Sort-Object CPUMed -Descending | Select-Object -First 10

# Filtrar apenas alertas
$data | Where-Object { $_.Alerta -ne "" } |
    Select-Object Timestamp, ProcessName, CPU_Pct, MemWorkingSet_MB, Alerta |
    Sort-Object Timestamp
```

**Verificar se o script esta em execucao**
```powershell
Get-Process powershell | Select-Object Id, CPU, StartTime
```

---

*Monitor-TodosProcessos.ps1 - Windows Process Monitor | PowerShell 5.1+*
