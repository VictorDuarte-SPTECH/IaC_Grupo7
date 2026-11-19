# Carga na infraestrutura principal pelo ALB

O plano [atividade-tres-grupos.jmx](atividade-tres-grupos.jmx) usa JMeter
5.6.3, sem plugins, para a infraestrutura
[cloudformationCodeTracker.yaml](../IaC%20CloudFormation/cloudformationCodeTracker.yaml).
Todas as chamadas usam o DNS do output `ApplicationUrl`, porta 80, com
prefixo `/api`. Nao use IP de EC2, DNS do antigo NLB nem porta 8080.
O template economico nao tem Load Balancer; este plano nao se destina a ele.

## Cenarios e fluxo

Os tres grupos executam **sequencialmente**, nao somam 122 usuarios:

| Grupo | Usuarios virtuais | Rampa | Duracao total | Patamar nominal apos rampa |
| --- | ---: | ---: | ---: | ---: |
| G1 | 2 | 2 s | 300 s | 298 s |
| G2 | 20 | 20 s | 300 s | 280 s |
| G3 | 100 | 60 s | 300 s | 240 s |

A duracao inclui a rampa; o fluxo repete ate o prazo, em vez de terminar
apos cinco iteracoes. Ha ainda um setUp de uma thread para validar parametros
localmente, sem HTTP; ele nao e um quarto cenario de carga.
O termino pode exceder o prazo por requisicoes em andamento.
Nao ha intervalo de recuperacao automatico entre grupos.

Cada usuario faz login e mantem seu proprio cookie `authToken`, renovando
o login 30 segundos antes da expiracao JWT. O login chama tambem
`GET /api/usuarios/{userId}` e abre o Dashboard, como
[Login.jsx](../../FrontEnd_Grupo7/codetracker/src/pages/Login.jsx).
As antigas consultas genericas a `/usuarios/me`, `/clientes` e
`/periodos/estoque-atual` foram removidas deste plano.

### Mesmo conteudo ou conteudos diferentes

- **`-Jnavegacao=diferentes` (padrao):** distribui usuarios entre Dashboard,
  Pecas, Periodos e Pedidos por round-robin. A cada navegacao completa,
  cada usuario avanca de tela. IDs sao escolhidos das respostas, variando
  por thread/ciclo. Com poucos registros, usuarios podem repetir conteudo;
  Dashboard/ultimo periodo sao naturalmente compartilhados.
- **`-Jnavegacao=mesmo -Jtela=pecas`:** todos repetem a mesma jornada e
  abrem o primeiro registro retornado. `tela` aceita tambem `dashboard`,
  `periodos` e `pedidos`. Pedidos usa o filtro ENTRADA nesse modo.
  Apos login todos ainda carregam o Dashboard inicial. Para comparar a
  mesma entidade, mantenha dados/ordenacao estaveis durante a rodada.

Cada navegacao representa reabrir uma tela e clicar em "Ver mais".
Nao executa botoes de criar/editar/excluir/fechar periodo ou gerar etiquetas.

| Tela / acao | Chamadas reais pelo ALB (todas GET, exceto login POST) |
| --- | --- |
| [Dashboard](../../FrontEnd_Grupo7/codetracker/src/pages/Dashboard.jsx) | `/api/periodos/ultimo`, `/api/movimentacoes/dados-mensais?ano=ANO_ATUAL`, `/api/movimentacoes/{periodoId}/status-cotacoes` |
| [Pecas](../../FrontEnd_Grupo7/codetracker/src/pages/Pecas.jsx) | `/api/itens?page=0&size=1000`, depois `/api/itensNaMovimentacao/item/{id}` para **cada** item retornado, como a carga de quantidades da tela |
| [Detalhe da peca](../../FrontEnd_Grupo7/codetracker/src/pages/VerMaisPecas.jsx) | `/api/itens/{id}`, `/api/itensNaMovimentacao/item/{id}`, `/api/itens/{id}/precos-medios`, `/api/itens/{id}/similares`, `/api/movimentacoes/{id}/fornecedores-estatisticas` |
| [Periodos](../../FrontEnd_Grupo7/codetracker/src/pages/Periodo.jsx) e [detalhe](../../FrontEnd_Grupo7/codetracker/src/pages/VerMaisPeriodo.jsx) | `/api/periodos`; ao abrir detalhe, novamente `/api/periodos` e `/api/itensNaMovimentacao/item/periodo/{id}` |
| [Pedidos](../../FrontEnd_Grupo7/codetracker/src/pages/Pedidos.jsx) | `/api/periodos/ultimo`, `/api/movimentacoes/periodo/{id}`; depois aplica o filtro de tipo da tela: `/api/movimentacoes/buscar?tipo=ENTRADA`, `SAIDA` ou `COTACAO` |
| [Detalhe do pedido](../../FrontEnd_Grupo7/codetracker/src/pages/VerMaisPedidos.jsx) | ID escolhido na lista filtrada: `/api/movimentacoes/{id}`, `/api/itensNaMovimentacao/movimentacao/{id}`. Saida com origem consulta a cotacao e seus itens; cotacao concluida procura `/api/movimentacoes/tipo/SAIDA` e os itens da saida associada, quando existente |

O plano valida status, JSON e campos essenciais usados pelas telas.
Similares aceita HTTP 200 com lista de IDs numericos ou HTTP 204
(peca sem similares), conforme o controller. Outros erros continuam
reprovando a amostra; 204 nao e aceito genericamente nos demais endpoints.
Catalogo aceita lista ou `content`, como o frontend; 204/lista vazia
pula o detalhe. Listas vazias de periodos/pedidos tambem pulam detalhes,
com aviso no log; nao representam cobertura desses detalhes.
Prepare dados representativos para todas as jornadas.
Filas de chamadas e IDs sao privados por thread; respostas invalidas
nao geram consultas dependentes com IDs inventados ou de ciclos anteriores.
Os rotulos no relatorio incluem tela e acao, sem IDs para evitar milhares
de series. O preparo local das jornadas nao conta como amostra HTTP.
Cada requisicao tem pausa de 500 a 1000 ms,
timeout de conexao de 5 s, de resposta de 10 s e assercao de duracao de 5 s.
Esses valores sao hipoteses iniciais, nao um SLA acordado.
Redirects nao sao seguidos para evitar sair do destino ou mascarar erros.
Falha de login/cookie/JWT ou HTTP 401/403/429 interrompe o teste, sem
retry automatico; outras falhas sao registradas e a carga continua.

Nao cria/edita/exclui dados de negocio, gera etiquetas ou envia emails.
Login ainda produz logs e atualiza o controle de tentativas.

### Divergencias frontend/backend que o teste deve revelar

No codigo local, Dashboard chama `/movimentacoes/dados-mensais?ano=...`,
mas o controller backend declara `/{id}/dados-mensais`. Pedidos espera
uma lista na carga inicial, enquanto o backend declara
`{conteudo, offset, limit, totalItens}`. O plano reproduz as rotas e
expectativas do **frontend**, sem trocar silenciosamente para outra rota
nem desembrulhar uma pagina que a tela nao interpreta.
Essas chamadas podem falhar na infraestrutura implantada, dependendo da
tag Docker. O filtro de Pedidos segue sendo testado e fornece os IDs para
o detalhe mesmo se a listagem inicial falhar. Corrigir as aplicacoes esta
fora desta alteracao do teste.
Falhas das consultas opcionais do detalhe da peca continuam registradas,
mesmo que a interface permita abrir a pagina parcialmente.

## Execucao

### Relatorios automaticos (recomendado)

Use [Executar-TesteCarga.ps1](Executar-TesteCarga.ps1) no PowerShell, nesta
pasta. Nao e necessario abrir o JMeter ou alterar o CloudFormation:

```powershell
.\Executar-TesteCarga.ps1 `
    -DestinoAlb 'lamar-auto-pecas-alb-1544116602.us-east-1.elb.amazonaws.com'
```

O script pede a senha de forma oculta se `JMETER_PASSWORD` nao estiver
definida; restaura o valor anterior ao terminar o teste. O DNS e obrigatorio
para evitar carga acidental no destino salvo no JMX. Os demais parametros
padrao sao email `admin@teste.com`, HTTP/80, todos os grupos e 300 s por grupo.
Se o Windows bloquear scripts locais, e a politica da sua organizacao
permitir, use `powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File
.\Executar-TesteCarga.ps1 -DestinoAlb 'DNS_DO_ALB'`. Essa opcao vale somente
para o novo processo; nao altera a politica permanente.
Para conferir com pouca carga primeiro:

```powershell
.\Executar-TesteCarga.ps1 -DestinoAlb 'DNS_DO_ALB' -Grupo 2 -DuracaoSegundos 30
```

Outras opcoes: `-Email`, `-Protocolo https` (porta padrao 443), `-Porta`,
`-Navegacao diferentes` (padrao) ou `-Navegacao mesmo -Tela pecas`,
`-PastaSaida` e `-JMeterPath 'C:\caminho\apache-jmeter-5.6.3\bin\jmeter.bat'`.
O JMeter e procurado no PATH e depois em
`$env:USERPROFILE\Documents\apache-jmeter-5.6.3\bin\jmeter.bat`.
A duracao deve superar a maior rampa do grupo selecionado.

Exemplo de todos consultando a mesma peca:

```powershell
.\Executar-TesteCarga.ps1 -DestinoAlb 'DNS_DO_ALB' -Navegacao mesmo -Tela pecas
```

O comando sem `-Navegacao` simula navegacao distribuida nas quatro telas.
Os grupos 2/20/100, duracoes e relatorios automaticos permanecem iguais.

Cada execucao cria uma subpasta unica em `resultados` ao lado do script,
independentemente da pasta atual do terminal (ou em `-PastaSaida`, se
informada), contendo:

- `resultado.jtl`: amostras CSV, sem corpos, headers, URL ou senha;
- `jmeter.log` e `dashboard.log`: diagnostico;
- `dashboard/index.html`: dashboard HTML padrao do JMeter;
- `resumo.html` e `resumo.csv`: total por grupo e por grupo/endpoint,
  com quantidade, falhas, erro %, media, p50/p95/p99, maximo, janela,
  RPS e pico de threads do grupo observado nas amostras.

O resumo exclui a pre-validacao das estatisticas HTTP, mas contabiliza suas
falhas. Percentis usam nearest-rank sobre todos os tempos, incluindo falhas.
RPS usa a janela do primeiro inicio ao ultimo termino de cada linha,
incluindo rampa, login e pausas. Nao representa RPS de patamar isolado.
Os dados sao carregados em memoria para ordenar os percentis; arquivos
muito grandes exigem RAM proporcional. O dashboard pode usar aproximacoes
de percentis diferentes do resumo.

Se houver amostras reprovadas, o script gera os relatorios disponiveis e
termina com erro explicito, mesmo que o processo JMeter retorne zero.
Nao ha aprovacao automatica por SLA nem comprovacao de balanceamento.
Arquivos e mensagens de erro podem conter dados da aplicacao; restrinja
acesso e nao versione os resultados.

Para gerar relatorios de uma execucao **ja salva**, sem enviar requisicoes:

```powershell
.\Executar-TesteCarga.ps1 -ArquivoJtl '.\resultado-anterior.jtl'
```

O JTL original nao e alterado. Precisa ser CSV com cabecalho separado por
virgulas, timestamp em milissegundos e campos padrao do dashboard JMeter.
O resumo exige `timeStamp`, `elapsed`, `label`, `success` e `grpThreads`,
com os rotulos `G1 - 2 usuarios :: ...`, `G2 - 20 usuarios :: ...` e
`G3 - 100 usuarios :: ...`. Uma execucao feita na GUI sem salvar amostras
em JTL nao pode ser reconstruida apenas pelo `jmeter.log`.

### Execucao manual

Execute o JMeter **fora das EC2 testadas**, em modo nao grafico.
Confirme autorizacao, janela de teste, backup e monitoramento, com os dois
targets `healthy`, servicos Swarm e banco operacionais. Confira a tag Docker
implantada: o contrato local pode divergir da imagem.
Mantenha periodos, pecas e pedidos de teste disponiveis para correlacionar
os detalhes; o plano nao cria registros.

O template principal publica somente HTTP. O backend local tem
`COOKIE_SECURE=true` por padrao: se a imagem implantada mantiver esse valor,
o plano para explicitamente porque o cookie nao pode ser usado sobre HTTP.
Para ambiente real, configure listener/certificado HTTPS e propagacao
correta de `X-Forwarded-Proto`, usando `-Jprotocolo=https -Jporta=443`.
Apenas em laboratorio isolado, sem dados/credenciais reais, avalie
`COOKIE_SECURE=false` no deploy. O plano nao altera essa configuracao nem
ignora a seguranca de cookies. HTTP expoe senha, sessao e dados em transito.

Exemplo PowerShell na pasta deste plano, com `jmeter.bat` no PATH:

```powershell
$segredo = Read-Host 'Senha da conta de teste' -AsSecureString
$env:JMETER_PASSWORD = [System.Net.NetworkCredential]::new('', $segredo).Password
$rodada = Get-Date -Format 'yyyyMMdd-HHmmss'
try {
    & jmeter.bat -n -t '.\atividade-tres-grupos.jmx' `
        '-Jhost=DNS_DO_ALB_SEM_PROTOCOLO' '-Jemail=admin@teste.com' `
        "-Jrodada=$rodada" `
        -l ".\resultado-$rodada.jtl" -j ".\jmeter-$rodada.log" `
        -e -o ".\relatorio-$rodada"
} finally {
    Remove-Item Env:\JMETER_PASSWORD
    Remove-Variable segredo
}
```

Nao informe a senha em `-J`, no JMX ou em arquivos versionados.
O host e obrigatorio: retire `http://` e qualquer caminho do output.
O exemplo executa os tres grupos, cerca de 15 minutos mais finalizacao.
Primeiro acrescente `-Jgrupo=2 -Jduracao_s=30` para conferir destino,
autenticacao e dados com pouca carga; so depois execute a sequencia.
Use arquivos/pastas novos a cada rodada (o dashboard exige destino vazio).

| Parametro `-J...` | Padrao / limites |
| --- | --- |
| `host` | Obrigatorio; DNS do ALB, sem esquema/porta/caminho |
| `grupo` | `todos`; tambem aceita `2`, `20` ou `100`, isoladamente |
| `navegacao` | `diferentes`; ou `mesmo` para repetir uma jornada |
| `tela` | `pecas`; usada somente em `navegacao=mesmo`; aceita `dashboard`, `periodos`, `pedidos` |
| `email` | `admin@teste.com`; prefira conta dedicada, ativa |
| `protocolo`, `porta` | `http`, `80`; TLS exige listener configurado |
| `duracao_s` | 300 por grupo; 2 a 86400; maior que a rampa dos selecionados |
| `rampa_2_s`, `rampa_20_s`, `rampa_100_s` | 2, 20 e 60; 1 a 86399 |
| `pausa_ms`, `variacao_ms` | 500 e 500; cada um entre 0 e 60000 |
| `limite_resposta_ms` | 5000; 1 a 600000 |
| `timeout_conexao_ms`, `timeout_resposta_ms` | 5000 e 10000; 1 a 600000 |
| `rodada` | `manual`; use identificador unico simples, sem espacos |

## Como comprovar o balanceamento

O caminho e **JMeter -> ALB -> dois targets web/Nginx -> VIP do Swarm ->
quatro replicas de backend -> MySQL**. Sao duas camadas de distribuicao.
O JMX garante o destino configurado, mas nao descobre sozinho se esse DNS
e o ALB correto nem identifica o servidor por uma resposta JSON comum.

1. Confirme o DNS no output `ApplicationUrl` e os dois destinos saudaveis
   no target group web. O health check `/` so valida o frontend, nao toda a API.
2. **Habilite previamente access logs do ALB em S3**, com as permissoes do
   bucket. O template principal nao os habilita. Isso envolve armazenamento
   e custos; o plano nao altera recursos AWS.
3. Nos logs, filtre o intervalo UTC e o User-Agent
   `CodeTracker-JMeter/IDENTIFICADOR_DA_RODADA`, presente em todas as chamadas.
   Conte por `target:port` e por endpoint, verificando status e tempos.
   Devem existir chamadas nos **dois IPs privados web**, mapeados as EC2.
   Os logs chegam com atraso e sao best-effort: corroboram a distribuicao,
   mas nao sao contabilizacao exata de todas as requisicoes.
4. Compare tambem logs/metricas dos dois Nginx e das **quatro tasks backend**
   durante a rodada. Logs do ALB identificam os targets web, nao a task
   escolhida pela VIP do Swarm. Sem identificacao/telemetria por task,
   nao e possivel comprovar distribuicao entre as replicas Java.

Nao espere 50/50 exato, especialmente com dois usuarios. Confira algoritmo,
stickiness, cross-zone e saude efetivamente implantados. Keep-alive fica
ativo, como num cliente real; nao implica afinidade garantida em um ALB HTTP.
Este plano nao desliga destinos e **nao testa failover**, isolamento de AZ
ou recuperacao de banco. Isso exige experimento separado e controlado.

## Limitacoes e interpretacao

- **Usuarios nao sao RPS:** sao 2/20/100 sessoes concorrentes, nao o mesmo
  numero de requisicoes simultaneamente em voo. Pausas e latencia limitam
  throughput. E um modelo fechado: quando o servidor fica lento, o proprio
  gerador envia menos requisicoes; nao prova capacidade para chegada fixa
  de trafego nem mede sozinho todos os efeitos de fila.
- Todos usam a mesma conta, mas cada thread tem cookie/fila independentes.
  Isso nao representa diversidade de permissoes/usuarios cadastrados.
  A escolha de registros se limita aos dados retornados pela tela (Pecas
  carrega ate 1000 itens). Listas completas e volume de dados mudam o custo.
  As chamadas das telas sao serializadas por usuario no JMeter; o frontend
  usa `Promise.all` em varios pontos. O plano reproduz as consultas e suas
  dependencias, **nao** as rajadas paralelas de cada navegador, cache HTTP,
  downloads de JS/CSS/imagens, renderizacao ou Web Vitals.
  Ha concorrencia entre usuarios, nao garantia de iniciar todas as chamadas
  no mesmo milissegundo.
  A tela Pecas dispara N consultas de quantidade mais 5 de detalhe por
  navegacao; com pausas, um catalogo grande pode impedir terminar a jornada
  em 5 minutos. Nao foi colocado limite artificial menor que o da tela:
  avalie volume, duracao e RPS antes de executar 100 usuarios.
  Escrita, locks de movimentacao, frontend/browser, CORS, SMTP e RabbitMQ
  ficam fora deste teste.
- Verifique segredo JWT e relogio coerentes em todas as replicas. Credenciais
  erradas podem bloquear a conta (codigo local: 5 falhas, 15 minutos);
  chamadas ja em voo ainda podem falhar durante a parada.
- Separe rampa, patamar e login na analise. Os rotulos incluem grupo e
  endpoint para comparar taxa de erros, RPS, p50/p95/p99 e bytes. O terceiro
  grupo herda aquecimento/pressao dos anteriores; repita rodadas isoladas
  com `grupo` e recuperacao para comparacoes mais controladas.
- Monitore `AWS/ApplicationELB`: `RequestCount`, `TargetResponseTime`,
  `HTTPCode_ELB_5XX_Count`, `HTTPCode_Target_5XX_Count`, `HealthyHostCount`,
  `UnHealthyHostCount`, `TargetConnectionErrorCount` e conexoes.
  Acompanhe CPU/creditos T3, RAM/swap, rede, disco, GC/heap Java,
  reinicios de containers, pool Hikari e conexoes/consultas lentas/locks
  MySQL. Some os pools das quatro replicas; MySQL pode saturar antes da API.
  RAM/GC/metricas internas exigem agente/exporter; o JMX nao os instala.
- Monitore tambem CPU/RAM/rede do gerador, latencia/rota ate a AWS,
  localizacao, VPN/proxy, banda e outros consumidores do ambiente. Um gerador
  saturado invalida conclusoes. Nao multiplique geradores sem recalcular a
  concorrencia total; nao habilite listeners graficos pesados.
- Defina criterios antes da execucao (por exemplo, erro < 1% e p95 < 2 s,
  **apenas exemplos**, com janela de medicao acordada).
  A assercao de 5 s e individual, nao um criterio agregado de p95.
  JMeter pode retornar exit code zero mesmo com falhas; confira `success`
  no JTL, mensagens de assercao e dashboard.
- Interrompa com parada graciosa do JMeter diante de indisponibilidade
  sustentada, OOM, reinicios, saturacao do banco ou limites de custo.
  Combine gatilhos numericos com o responsavel; nao ha corte automatico
  por CPU, taxa de erros ou percentis.
- ALB/LCU, EC2/creditos, transferencia, S3 e logs podem gerar custos.
  Nao grave corpos/headers, cookies ou credenciais nos resultados;
  restrinja acesso aos arquivos. Este plano nao comprova balanceamento
  sem as evidencias externas descritas acima.
