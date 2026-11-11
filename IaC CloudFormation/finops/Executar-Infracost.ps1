param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('principal', 'datalake', 'observabilidade')]
    [string]$Template,
    [ValidateRange(5, 1800)]
    [int]$TimeoutSeconds = 180
)

# Windows PowerShell 5.1. Nao executa deploy nem confirma o login da CLI.
$ErrorActionPreference = 'Stop'
$definitions = @{
    principal = @{ File = 'cloudformationCodeTracker.yaml'; Title = 'Infraestrutura principal' }
    datalake = @{ File = 'buckets+lambda.yml'; Title = 'Data lake - Lambda, S3 e Glue' }
    observabilidade = @{ File = 'observabilidade-ti.yaml'; Title = 'Observabilidade - CloudWatch e SNS' }
}
$definition = $definitions[$Template]
$source = Join-Path (Split-Path $PSScriptRoot -Parent) $definition.File
$results = Join-Path $PSScriptRoot 'resultados'
$executable = Join-Path $env:LOCALAPPDATA 'Programs\Infracost\infracost.exe'
if (-not (Test-Path -LiteralPath $executable)) {
    $executable = (Get-Command infracost -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $source)) {
    throw "Template nao encontrado: $source"
}

New-Item -ItemType Directory -Force -Path $results | Out-Null
# scan recebe um diretorio. A copia isolada evita incluir os outros templates.
$inputDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ('infracost-' + $Template + '-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $inputDirectory | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $inputDirectory $definition.File)
$log = Join-Path $results ($Template + '.log')
$markdown = Join-Path $results ($Template + '.md')
$statusFile = Join-Path $results ($Template + '.status.json')
$timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
$previousCI = $env:CI
$env:CI = 'true'
$scanExitCode = 1
$timedOut = $false
$lines = New-Object 'System.Collections.Generic.List[string]'

try {
    $header = @(
        '============================================================',
        ('INFRACOST | ' + $definition.Title),
        ('Template: ' + $definition.File),
        ('Data: ' + $timestamp),
        ('Origem: ' + $source),
        'Modo: leitura, sem deploy; moeda: USD; parametros default.',
        'Somente este template foi copiado para o diretorio de analise.',
        '============================================================'
    )
    $header | ForEach-Object { Write-Host $_; $lines.Add($_) }
    # O usuario decidiu nao autenticar agora; nao confirmar prompts de login.
    $ErrorActionPreference = 'Continue'
    & $executable --version 2>&1 | ForEach-Object {
        $line = [string]$_; Write-Host $line; $lines.Add($line)
    }
    Write-Host ('Comando: infracost scan "' + $inputDirectory + '" --currency USD --no-color')
    $ErrorActionPreference = 'Stop'
    $scan = New-Object System.Diagnostics.Process
    $scan.StartInfo.FileName = $executable
    $scan.StartInfo.Arguments = 'scan "' + $inputDirectory + '" --currency USD --no-color'
    $scan.StartInfo.UseShellExecute = $false
    $scan.StartInfo.CreateNoWindow = $true
    $scan.StartInfo.RedirectStandardOutput = $true
    $scan.StartInfo.RedirectStandardError = $true
    $scan.StartInfo.RedirectStandardInput = $true
    try {
        [void]$scan.Start()
        $stdout = $scan.StandardOutput.ReadToEndAsync()
        $stderr = $scan.StandardError.ReadToEndAsync()
        if (-not $scan.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            $scan.Kill()
            $scan.WaitForExit()
            $scanExitCode = 124
        } else {
            $scanExitCode = $scan.ExitCode
        }
        $captured = $stdout.Result + "`n" + $stderr.Result
    } finally {
        $scan.Dispose()
    }
    $authenticationRequired = $captured -match '(?i)log in|authenticate|not authenticated'
    $captured -split '\r?\n' | ForEach-Object {
        $line = $_ -replace 'https://login\.infracost\.io/authorize\?\S+', '[URL temporaria de login omitida]'
        Write-Host $line
        $lines.Add($line)
    }
    if ($timedOut) {
        $message = "Tempo limite local de $TimeoutSeconds segundos atingido; processo encerrado sem confirmar login."
        Write-Host $message
        $lines.Add($message)
    }
    $summary = if ($scanExitCode -eq 0) {
        'Scan concluido. Conferir recursos nao precificados e premissas antes de usar os totais.'
    } else {
        'Scan nao concluido. Custo indisponivel: falha NAO significa custo zero.'
    }
    Write-Host ''
    Write-Host $summary -ForegroundColor $(if ($scanExitCode -eq 0) { 'Green' } else { 'Yellow' })
    Write-Host ('Codigo de saida: ' + $scanExitCode)
    Write-Host ('Log: ' + $log)
    Write-Host 'Este terminal pode ser usado para captura de tela.'
    $lines.Add($summary)
    $lines.Add('Codigo de saida: ' + $scanExitCode)
    $lines | Set-Content -LiteralPath $log -Encoding UTF8
    $fence = '```'
    @(
        ('# Infracost - ' + $definition.Title),
        '',
        ('- Template: `' + $definition.File + '`'),
        ('- Executado em: ' + $timestamp),
        ('- Codigo de saida: ' + $scanExitCode),
        '- Moeda solicitada: USD. Parametros: defaults do template.',
        '- Analise direta de CloudFormation, sem conversao para Terraform.',
        '- Nenhum recurso foi criado, alterado ou excluido na AWS.',
        '',
        $summary,
        '',
        '## Saida da execucao',
        '',
        ($fence + 'text'),
        $lines.ToArray(),
        $fence
    ) | Set-Content -LiteralPath $markdown -Encoding UTF8
    [ordered]@{
        template = $definition.File
        executedAt = $timestamp
        exitCode = $scanExitCode
        completed = ($scanExitCode -eq 0)
        timedOut = $timedOut
        authenticationRequired = $authenticationRequired
        currency = 'USD'
        log = $log
    } | ConvertTo-Json | Set-Content -LiteralPath $statusFile -Encoding UTF8
} finally {
    $env:CI = $previousCI
    if (Test-Path -LiteralPath $inputDirectory) {
        Remove-Item -LiteralPath $inputDirectory -Recurse -Force
    }
}
exit $scanExitCode
