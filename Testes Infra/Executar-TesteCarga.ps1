[CmdletBinding(DefaultParameterSetName = 'Executar')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Executar')]
    [ValidatePattern('^[a-zA-Z0-9][a-zA-Z0-9.-]*$')]
    [string]$DestinoAlb,

    [Parameter(Mandatory = $true, ParameterSetName = 'Relatorio')]
    [string]$ArquivoJtl,

    [string]$JMeterPath,

    [Parameter(ParameterSetName = 'Executar')]
    [string]$Email = 'admin@teste.com',

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateSet('todos', '2', '20', '100')]
    [string]$Grupo = 'todos',

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateSet('mesmo', 'diferentes')]
    [string]$Navegacao = 'diferentes',

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateSet('dashboard', 'pecas', 'periodos', 'pedidos')]
    [string]$Tela = 'pecas',

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateRange(3, 86400)]
    [int]$DuracaoSegundos = 300,

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateSet('http', 'https')]
    [string]$Protocolo = 'http',

    [Parameter(ParameterSetName = 'Executar')]
    [ValidateRange(1, 65535)]
    [int]$Porta,

    [ValidateNotNullOrEmpty()]
    [string]$PastaSaida
)

$ErrorActionPreference = 'Stop'
$invariant = [Globalization.CultureInfo]::InvariantCulture
if (-not $PSBoundParameters.ContainsKey('PastaSaida')) {
    $PastaSaida = Join-Path $PSScriptRoot 'resultados'
}

function Get-Percentil {
    param([long[]]$Ordenados, [double]$Percentil)
    return $Ordenados[[int][Math]::Ceiling($Ordenados.Length * $Percentil) - 1]
}

function New-Resumo {
    param([object[]]$Amostras, [string]$GrupoNome, [string]$Endpoint)
    $tempos = [long[]]@($Amostras | ForEach-Object { $_.TempoMs } | Sort-Object)
    $inicio = ($Amostras | Measure-Object Inicio -Minimum).Minimum
    $fim = ($Amostras | Measure-Object Fim -Maximum).Maximum
    $janela = ($fim - $inicio) / 1000.0
    $falhas = @($Amostras | Where-Object { -not $_.Sucesso }).Count
    $rps = $null
    if ($janela -gt 0) { $rps = [Math]::Round($Amostras.Count / $janela, 3) }
    return [pscustomobject][ordered]@{
        Grupo = $GrupoNome
        Endpoint = $Endpoint
        Amostras = $Amostras.Count
        Falhas = $falhas
        ErroPercentual = [Math]::Round(100.0 * $falhas / $Amostras.Count, 3)
        MediaMs = [Math]::Round(($tempos | Measure-Object -Average).Average, 3)
        P50Ms = Get-Percentil $tempos 0.50
        P95Ms = Get-Percentil $tempos 0.95
        P99Ms = Get-Percentil $tempos 0.99
        MaximoMs = $tempos[-1]
        JanelaSegundos = [Math]::Round($janela, 3)
        Rps = $rps
        PicoThreadsGrupo = ($Amostras | Measure-Object Threads -Maximum).Maximum
    }
}

if ($PSCmdlet.ParameterSetName -eq 'Relatorio') {
    $ArquivoJtl = (Resolve-Path -LiteralPath $ArquivoJtl).Path
} else {
    $rampaMaxima = switch ($Grupo) { '2' { 2 } '20' { 20 } default { 60 } }
    if ($DuracaoSegundos -le $rampaMaxima) {
        throw "DuracaoSegundos deve ser maior que a rampa de $rampaMaxima segundos."
    }
}

if (-not $JMeterPath) {
    $comando = Get-Command 'jmeter.bat' -ErrorAction SilentlyContinue
    if ($comando) {
        $JMeterPath = $comando.Source
    } else {
        $JMeterPath = Join-Path $env:USERPROFILE 'Documents\apache-jmeter-5.6.3\bin\jmeter.bat'
    }
}
$JMeterPath = (Resolve-Path -LiteralPath $JMeterPath).Path
$rodada = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$saida = Join-Path $PastaSaida $rodada
New-Item -ItemType Directory -Path $saida | Out-Null
$saida = (Resolve-Path -LiteralPath $saida).Path
$logJMeter = Join-Path $saida 'jmeter.log'
$codigoExecucao = 0

if ($PSCmdlet.ParameterSetName -eq 'Executar') {
    if (-not $PSBoundParameters.ContainsKey('Porta')) {
        $Porta = if ($Protocolo -eq 'https') { 443 } else { 80 }
    }
    $ArquivoJtl = Join-Path $saida 'resultado.jtl'
    $senhaAnterior = $env:JMETER_PASSWORD
    try {
        if (-not $env:JMETER_PASSWORD) {
            $segredo = Read-Host 'Senha da conta de teste da aplicacao' -AsSecureString
            $env:JMETER_PASSWORD = [System.Net.NetworkCredential]::new('', $segredo).Password
        }
        Write-Host "Destino: ${Protocolo}://${DestinoAlb}:$Porta | grupo: $Grupo | duracao por grupo: $DuracaoSegundos s"
        $argumentos = @(
            '-n', '-t', (Join-Path $PSScriptRoot 'atividade-tres-grupos.jmx'),
            "-Jhost=$DestinoAlb", "-Jemail=$Email", "-Jgrupo=$Grupo",
            "-Jduracao_s=$DuracaoSegundos", "-Jprotocolo=$Protocolo", "-Jporta=$Porta",
            "-Jrodada=$rodada", "-Jnavegacao=$Navegacao", "-Jtela=$Tela",
            '-l', $ArquivoJtl, '-j', $logJMeter,
            '-Jjmeter.save.saveservice.output_format=csv',
            '-Jjmeter.save.saveservice.default_delimiter=,',
            '-Jjmeter.save.saveservice.print_field_names=true',
            '-Jjmeter.save.saveservice.timestamp_format=ms',
            '-Jjmeter.save.saveservice.time=true',
            '-Jjmeter.save.saveservice.label=true',
            '-Jjmeter.save.saveservice.successful=true',
            '-Jjmeter.save.saveservice.thread_counts=true',
            '-Jjmeter.save.saveservice.response_code=true',
            '-Jjmeter.save.saveservice.response_message=true',
            '-Jjmeter.save.saveservice.thread_name=true',
            '-Jjmeter.save.saveservice.data_type=true',
            '-Jjmeter.save.saveservice.bytes=true',
            '-Jjmeter.save.saveservice.sent_bytes=true',
            '-Jjmeter.save.saveservice.latency=true',
            '-Jjmeter.save.saveservice.connect_time=true',
            '-Jjmeter.save.saveservice.idle_time=true',
            '-Jjmeter.save.saveservice.assertion_results_failure_message=true',
            '-Jjmeter.save.saveservice.response_data=false',
            '-Jjmeter.save.saveservice.response_data.on_error=false',
            '-Jjmeter.save.saveservice.samplerData=false',
            '-Jjmeter.save.saveservice.requestHeaders=false',
            '-Jjmeter.save.saveservice.responseHeaders=false',
            '-Jjmeter.save.saveservice.url=false'
        )
        '' | & $JMeterPath @argumentos
        $codigoExecucao = $LASTEXITCODE
    } finally {
        $env:JMETER_PASSWORD = $senhaAnterior
        if (Get-Variable segredo -ErrorAction SilentlyContinue) {
            $segredo.Dispose()
            Remove-Variable segredo
        }
    }
}

if (-not (Test-Path -LiteralPath $ArquivoJtl -PathType Leaf)) {
    throw "JTL nao foi gerado. Codigo JMeter: $codigoExecucao. Consulte $logJMeter"
}
$linhas = @(Import-Csv -LiteralPath $ArquivoJtl -Encoding UTF8)
if ($linhas.Count -eq 0) { throw 'JTL vazio; nao ha amostras para relatar.' }
$necessarias = @('timeStamp', 'elapsed', 'label', 'success', 'grpThreads')
foreach ($coluna in $necessarias) {
    if ($coluna -notin $linhas[0].PSObject.Properties.Name) {
        throw "JTL CSV deve conter $coluna (cabecalho com virgulas e timestamp em milissegundos)."
    }
}

$amostras = @()
$falhasTotais = 0
$ignoradas = 0
$linha = 1
$amostras = @(foreach ($registro in $linhas) {
    $linha++
    [long]$inicio = 0
    [long]$tempo = 0
    [int]$threads = 0
    if (-not [long]::TryParse($registro.timeStamp, [Globalization.NumberStyles]::Integer, $invariant, [ref]$inicio) -or
        -not [long]::TryParse($registro.elapsed, [Globalization.NumberStyles]::Integer, $invariant, [ref]$tempo) -or
        -not [int]::TryParse($registro.grpThreads, [ref]$threads) -or
        $inicio -lt 0 -or $tempo -lt 0 -or $threads -lt 0 -or
        $registro.success -notin @('true', 'false')) {
        throw "Amostra invalida na linha $linha do JTL."
    }
    if ($registro.success -eq 'false') { $falhasTotais++ }
    if ($registro.label -match '^(G[123] - (?:2|20|100) usuarios) :: (.+)$') {
        [pscustomobject]@{
            Grupo = $Matches[1]; Endpoint = $Matches[2]
            Inicio = $inicio; Fim = $inicio + $tempo
            TempoMs = $tempo; Sucesso = ($registro.success -eq 'true'); Threads = $threads
        }
    } else {
        $ignoradas++
    }
})

$resumos = @(foreach ($porGrupo in ($amostras | Group-Object Grupo | Sort-Object Name)) {
    New-Resumo $porGrupo.Group $porGrupo.Name 'TOTAL DO GRUPO'
    foreach ($porEndpoint in ($porGrupo.Group | Group-Object Endpoint | Sort-Object Name)) {
        New-Resumo $porEndpoint.Group $porGrupo.Name $porEndpoint.Name
    }
})
$csv = Join-Path $saida 'resumo.csv'
if ($resumos.Count -gt 0) {
    $resumos | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
}
$html = Join-Path $saida 'resumo.html'
$origem = [System.Net.WebUtility]::HtmlEncode($ArquivoJtl)
$tabela = if ($resumos.Count -gt 0) {
    ($resumos | ConvertTo-Html -Fragment) -join [Environment]::NewLine
} else {
    '<p>Nenhuma chamada HTTP reconhecida. Verifique a pre-validacao e os rotulos do plano.</p>'
}
$falhasHtml = if ($falhasTotais -gt 0) {
    '<h2>Amostras com falha (primeiras 20)</h2>' +
    ((@($linhas | Where-Object { $_.success -eq 'false' } | Select-Object -First 20 `
        label, responseCode, responseMessage, failureMessage) | ConvertTo-Html -Fragment) -join [Environment]::NewLine)
} else { '' }
@"
<!doctype html>
<html lang="pt-BR"><head><meta charset="utf-8"><title>Resumo de carga - $rodada</title>
<style>body{font-family:Segoe UI,sans-serif;margin:2rem}table{border-collapse:collapse;font-size:.9rem}th,td{border:1px solid #ccc;padding:.5rem}th{background:#eee}p{max-width:95ch}</style>
</head><body><h1>Resumo de carga</h1>
<p>Origem: $origem</p>
<p>Amostras no arquivo: $($linhas.Count). Falhas totais: $falhasTotais.
Amostras fora dos rotulos HTTP dos grupos: $ignoradas (incluem pre-validacao; excluidas das estatisticas abaixo).</p>
<p><a href="dashboard/index.html">Dashboard JMeter (quando gerado com sucesso)</a></p>
$tabela
<p>Tempos em ms, incluindo sucessos e falhas. Percentis exatos por nearest-rank.
RPS = amostras / intervalo entre o primeiro inicio e o ultimo termino da respectiva linha;
inclui pausas entre chamadas, rampa e login. Janela zero: RPS vazio.
PicoThreadsGrupo e a maior concorrencia de threads do grupo observada nessas amostras, nao requisicoes em voo.
TOTAL DO GRUPO agrega tambem login e todos os endpoints; nao soma percentis.</p>
<p>O relatorio nao separa rampa/patamar, nao valida SLA e nao comprova distribuicao entre destinos do ALB.
Falhas de assercao contam como erros mesmo com HTTP 200. Guarde os arquivos com acesso restrito.</p>
$falhasHtml
</body></html>
"@ | Set-Content -LiteralPath $html -Encoding UTF8

$dashboard = Join-Path $saida 'dashboard'
'' | & $JMeterPath '-g' $ArquivoJtl '-o' $dashboard '-j' (Join-Path $saida 'dashboard.log') `
    '-Jjmeter.save.saveservice.default_delimiter=,' '-Jjmeter.save.saveservice.timestamp_format=ms'
$codigoDashboard = $LASTEXITCODE
Write-Host "Resumo HTML: $html"
if ($resumos.Count -gt 0) { Write-Host "Resumo CSV: $csv" }
Write-Host "JTL: $ArquivoJtl"
if ($codigoDashboard -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $dashboard 'index.html'))) {
    throw "Falha ao gerar dashboard; resumo preservado. Consulte $(Join-Path $saida 'dashboard.log')"
}
Write-Host "Dashboard: $(Join-Path $dashboard 'index.html')"
if ($codigoExecucao -ne 0 -or $falhasTotais -gt 0 -or $amostras.Count -eq 0) {
    throw "Execucao com falhas ou sem chamadas HTTP reconhecidas. Codigo JMeter: $codigoExecucao; amostras com falha: $falhasTotais. Relatorios preservados em $saida"
}
