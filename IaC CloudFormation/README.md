# Deploy da aplicacao com CloudFormation e Docker Swarm

O template `cloudformationCodeTracker.yaml` instala Docker nas VMs da
aplicacao, MySQL na VM de banco e RabbitMQ em uma VM dedicada. O manager
descobre os quatro workers, aplica labels e executa `docker stack deploy`.

## 0. Preparar o ambiente

Este roteiro sobe a infraestrutura AWS pelo console do CloudFormation.
Nao e necessario executar os projetos Terraform, LocalStack ou o Compose
local para este deploy. O template principal cria a rede, oito EC2, dois NAT
Gateways, ALB, volume de banco e o cluster Swarm com a aplicacao.
O painel e os alertas sao uma segunda stack opcional, descrita no passo 4.

1. Disponibilize as pastas `IaC_Grupo7`, `BackEnd_Grupo7`, `FrontEnd_Grupo7`,
   `Etiquetas_Grupo7` e `Banco_Grupo7` no mesmo diretorio local. O script
   de publicacao usa as tres pastas de aplicacao para construir as imagens;
   na AWS, o banco e clonado diretamente do GitHub pelo bootstrap.
2. Instale e inicie o Docker Desktop com containers Linux. Tenha Bash
   (por exemplo, WSL com integracao do Docker Desktop) para executar o script.
   Use uma maquina Linux amd64 ou um ambiente Docker configurado para gerar
   imagens amd64, pois as VMs usam essa arquitetura.
3. Tenha uma conta Docker Hub com permissao para publicar imagens e os
   repositorios publicos `codetracker-backend`, `codetracker-frontend` e
   `codetracker-etiquetas`.
4. Entre no console AWS e selecione uma regiao com pelo menos duas AZs.
   Em laboratorios, inicie a sessao do laboratorio antes de abrir o console.
   Confira cotas e permissoes para oito EC2 `t3.small`, dois NAT Gateways,
   tres Elastic IPs, ALB, VPC, EBS, SSM e CloudFormation.
5. Em EC2 > Key pairs, crie ou selecione um par de chaves na mesma regiao.
   Guarde o arquivo privado `.pem`: ele sera usado no acesso pelo bastion.
6. Confira o instance profile que sera associado as VMs, como
   `LabInstanceProfile`, e as permissoes descritas no passo 2. O template
   nao cria esse perfil.
7. Separe senhas distintas para banco, RabbitMQ e administrador, alem da
   chave JWT Base64. O exemplo de geracao da chave no passo 2 usa PowerShell,
   sem instalar dependencias.
   Nao salve esses valores no repositorio.

**Atencao:** os recursos geram custos enquanto existirem, inclusive sem
acessos. As VMs backend continuam `t3.small` para o teste de carga, com duas
replicas por VM; essa configuracao nao garante memoria suficiente sob carga.
Use dados de laboratorio: o template usa HTTP, importa dados de demonstracao
e inclui segredos no UserData, conforme as limitacoes ao final.

## 1. Publicar as imagens corrigidas

Abra o terminal Bash no diretorio que contem as pastas dos repositorios.
Com Docker em execucao, execute:

```bash
bash IaC_Grupo7/publicar-dockerhub.sh guilhermebarros297 v1.0.1
```

Os tres repositorios no Docker Hub precisam ser publicos. A imagem anterior
do frontend usa `localhost:8080`; a nova usa `/api` em producao. Nao reutilize
uma tag antiga para a versao corrigida. A arquitetura esperada e Linux amd64.

O script solicita login no Docker Hub, constroi backend, etiquetas e frontend,
e publica as tres imagens. Substitua `guilhermebarros297` pelo seu namespace.
Se a tag `v1.0.1` ja foi usada, escolha uma nova e use a mesma no CloudFormation.
Antes de continuar, confirme no Docker Hub que a tag escolhida existe nos
tres repositorios e que todos estao publicos. Nao publique senhas ou a chave
JWT nas imagens: elas serao informadas na criacao da stack.

## 2. Criar uma stack nova

1. Na regiao escolhida, abra CloudFormation > Stacks > Create stack >
   With new resources (standard).
2. Selecione Choose an existing template > Upload a template file e envie
   `cloudformationCodeTracker.yaml`, localizado nesta pasta. Nao envie
   `observabilidade-ti.yaml` nesta etapa.
3. Avance e informe um nome de stack, por exemplo `lamar-app-teste`.
   O nome da stack e diferente de `EnvironmentName`, que prefixa os recursos.
4. Preencha os parametros abaixo. Mantenha `InstanceType=t3.small` para
   testar a carga com o tamanho atual.
5. Em Configure stack options, mantenha o rollback automatico e as demais
   opcoes padrao, salvo exigencias do seu ambiente. Se usar uma service role
   do CloudFormation, ela precisa ter permissao para criar os recursos e
   associar o instance profile.
6. Revise os parametros, avance e selecione Submit/Create stack.

Parametros a preencher:

- `EnvironmentName`: `lamar-auto-pecas`, ou outro prefixo exclusivo para
  esta implantacao, com ate 25 caracteres, letras, numeros e hifens.
- `DockerHubNamespace`: `guilhermebarros297`.
- `ApplicationImageTag`: `v1.0.1`, depois de publicar as tres imagens.
- `KeyName`: um par de chaves EC2 existente na regiao.
- `InstanceProfileName`: um perfil IAM existente, por exemplo `LabInstanceProfile`.
- `UbuntuAmiId`: mantenha o parametro SSM padrao do Ubuntu 24.04 amd64,
  desde que disponivel na regiao.
- `DatabaseName`, `DatabaseUser` e `RabbitMqUser`: mantenha `lamar` para
  este roteiro; `DatabaseName` obrigatoriamente deve ser `lamar`.
- `DatabasePassword` e `RabbitMqPassword`: senhas distintas com pelo menos 12 caracteres.
- `AdminPassword`: senha inicial de 12 a 72 caracteres para `admin@teste.com`,
  distinta da senha do MySQL. O bootstrap aplica um hash BCrypt ao administrador
  importado e falha se o usuario ativo com `ROLE_ADMIN` nao existir.
- `JwtSecret`: chave aleatoria codificada em Base64 que represente ao menos
  32 bytes (256 bits), nao uma senha de usuario. Gere uma nova no PowerShell:

  ```powershell
  $bytes = New-Object byte[] 32
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  try {
      $rng.GetBytes($bytes)
      [Convert]::ToBase64String($bytes)
  } finally {
      $rng.Dispose()
  }
  ```

  Copie a chave exibida para o parametro `JwtSecret` no CloudFormation.
  O comando usa aleatoriedade criptografica e funciona no Windows PowerShell
  5.1 e no PowerShell 7.
- `InstanceType`: `t3.small` por padrao em todas as VMs, inclusive as backend.
  Monitore memoria e CPU no teste de carga: duas replicas Java (limite de
  768 MiB cada) e etiquetas (512 MiB) dividem a mesma VM com o sistema
  operacional. Os limites somados ficam proximos dos 2 GiB da instancia,
  sem folga para o sistema; sob carga pode haver falta de memoria. Mais
  containers na mesma VM nao aumentam a capacidade de CPU da instancia.

Use uma regiao com ao menos duas zonas de disponibilidade e acesso ao parametro
SSM da AMI Ubuntu. O perfil das VMs precisa permitir `ssm:PutParameter` e
`ssm:GetParameter` em `/<EnvironmentName>/swarm/*`, `kms:Decrypt` para ler o
SecureString com a chave usada pelo SSM e `cloudformation:SignalResource` na
stack. Tambem sao necessarias `ssm:PutParameter` e `ssm:GetParameter` em
`/<EnvironmentName>/database/ready`. O usuario que cria a stack tambem precisa
poder associar esse perfil.

### Acompanhar a criacao

Na aba Events, acompanhe os recursos ate a stack atingir `CREATE_COMPLETE`.
O bootstrap pode levar dezenas de minutos; os sinais iniciais e a prontidao
do manager tem prazo de ate 60 minutos a partir da criacao de cada recurso.
Uma EC2 em estado `running` nao significa que a aplicacao esta pronta.

O processo e automatico: instala Docker, forma o Swarm, prepara MySQL e
RabbitMQ, importa o banco e publica os servicos. Nao execute `docker compose up`
nem `docker swarm init` manualmente nas VMs.

Se houver `CREATE_FAILED` ou `ROLLBACK_IN_PROGRESS`, localize na aba Events
o primeiro recurso com falha e consulte a secao Diagnostico. Corrija a causa
antes de tentar novamente; nao trate uma stack em rollback como implantada.
Se houver dados a preservar, faca backup antes de excluir qualquer stack.

### O que acontece durante o bootstrap

O manager publica `/<EnvironmentName>/swarm/stack-id` somente depois do IP e
do token. Os workers so usam esses parametros quando o marcador corresponde
ao ID da stack atual, evitando entrada em um cluster de uma implantacao antiga.
Nao execute stacks simultaneas com o mesmo `EnvironmentName` na mesma regiao.
Os oito bootstraps usam a mesma rotina definida em `Mappings.Bootstrap`:

- Atualizacao completa dos indices APT por IPv4, com timeout de ate 60 segundos
  por tentativa e janela total de 600 segundos. Tentativas ficam separadas por
  ate 10 segundos; a ultima tentativa usa apenas o tempo restante. A terminacao
  forcada de um processo pode acrescentar ate 5 segundos ao limite.
- Cada tentativa registra horario UTC, instancia, prazo restante, erro do APT
  e codigo de retorno em `/var/log/cloud-init-output.log`. Nenhum pacote e
  instalado se algum indice continuar indisponivel.
- Instalacao dos pacotes limitada a 600 segundos, com retries de download e
  novas tentativas de instalacao apos falhas transitorias do espelho Ubuntu,
  mantendo a espera limitada pelo lock do dpkg. Se a janela esgotar, a
  configuracao para; nao ha reexecucao de todo o script nem descarte do Swarm.
- Download da AWS CLI com timeout e retries limitados. A extracao sobrescreve
  arquivos temporarios sem perguntas interativas.
- Ao terminar, cada VM envia SUCCESS ou FAILURE ao `BootstrapWaitCondition`
  por uma URL S3 pre-assinada, sem depender da instalacao da AWS CLI ou de
  permissoes IAM adicionais para esse sinal. A URL e sensivel: nao a publique.

O `BootstrapWaitCondition` exige oito sinais unicos em ate 3600 segundos.
Uma falha identifica o recurso logico e a etapa, por exemplo
`WebInstanceAz1: apt-update-exhausted`; o motivo detalhado do APT fica no log.
Isso inclui bastion, banco e RabbitMQ.
O sucesso do bootstrap do manager nao substitui o teste da aplicacao.

O sinal pre-assinado precisa de acesso HTTPS ao endpoint S3 da URL, inclusive
em VPCs que usam endpoints com politicas restritivas. Para falhas antes de
instalar pacotes, a sinalizacao usa o curl ja presente na AMI Ubuntu selecionada.
Se a VM nao tiver curl, ou a rede impedir o acesso ao S3, nao ha como garantir
notificacao imediata: o log registra a impossibilidade e a stack falha pelo
timeout. A janela APT tolera uma indisponibilidade transitoria, mas nao corrige
rotas, NAT, ACLs ou security groups configurados incorretamente.

O ALB aguarda o Internet Gateway e as rotas publicas das duas subnets.
O bootstrap do manager sinaliza a `WaitCondition` assim que termina a
configuracao inicial e inicia o verificador do Swarm em segundo plano. A
`CreationPolicy` do `SwarmManagerInstance` continua pendente ate o manager
verificar os workers, as replicas e as respostas HTTP da aplicacao. O manager
aguarda ate 10 minutos pelos quatro workers antes de sinalizar falha; um worker
ainda iniciando nao derruba a stack. Depois, aguarda ate 15 minutos pelo banco
e 15 minutos pelas replicas e respostas HTTP. Falhas definitivas sao sinalizadas
ao CloudFormation, em vez de aguardar o timeout. O prazo do manager e de ate
60 minutos para acomodar
recuperacao de rede, instalacao e prontidao da aplicacao. Os prazos da
`WaitCondition` e do manager comecam quando seus respectivos recursos iniciam a
criacao; nao sao reiniciados por comandos manuais. O manager verifica as replicas,
o frontend e as respostas HTTP dos proxies do backend e de etiquetas pelo DNS
do ALB, sem anexar um container temporario a rede overlay do manager. A contagem
de replicas identifica cada servico e ignora o sufixo `(max 1 per node)` do Docker.
Respostas
4xx nas rotas raiz sao aceitas porque essas rotas podem nao existir ou exigir
autenticacao; isso nao substitui um teste funcional de login ou de pedidos.

## 3. Acessar a aplicacao

Depois de `CREATE_COMPLETE`, abra o output `ApplicationUrl`:

1. Abra a aba Outputs da stack principal e copie `ApplicationUrl`.
2. Acesse esse endereco no navegador. Nao use o IP privado das VMs nem
   `localhost:8080` no computador local.
3. Entre com `admin@teste.com` e a senha informada em `AdminPassword`.
   Confirme o acesso as telas e uma operacao de consulta da aplicacao.
4. Para conferir o cluster, copie `SwarmManagerSshCommand`, substitua
   `<chave.pem>` pelo caminho da chave privada e execute no seu terminal
   com cliente SSH. O comando acessa o manager privado pelo bastion.
5. No manager, execute:

```bash
sudo docker node ls
sudo docker service ls
sudo docker service ps codetracker_backend --filter desired-state=running
sudo docker service inspect codetracker_backend --format '{{.Spec.EndpointSpec.Mode}}'
```

Devem aparecer cinco nos no Swarm: um manager em `Drain` e quatro workers
em `Ready`/`Active`. Os servicos devem mostrar backend `4/4`, frontend `2/2`
e etiquetas `1/1`. Na lista de tarefas do backend, confira duas em
`backend-az1` e duas em `backend-az2`; o modo de endpoint deve ser `vip`.
Se isso nao ocorrer, consulte os logs antes de iniciar o teste de carga.

O fluxo de acesso fica assim:

```text
Navegador -> ALB :80 -> frontend/Nginx nas VMs web
                     -> /api/ -> VIP do backend -> 4 replicas :8080 na rede overlay
                     -> /etiquetas-api/ -> etiquetas :8081 na rede overlay
Backend -> MySQL :3306 na VM dedicada
Etiquetas -> backend :8080 na rede overlay
```

Ha duas replicas de frontend, uma por VM web, quatro de backend, duas por VM
backend, e uma de etiquetas em uma VM backend. O Nginx do frontend encaminha
cada requisicao `/api/` ao VIP do servico backend; o Swarm distribui as
conexoes entre as quatro replicas por round-robin (nao e afinidade por usuario).
O ALB distribui as conexoes externas entre os dois frontends. O manager fica
em modo drain.
Somente a porta do frontend e publicada; backend e etiquetas sao internos.
O acesso MySQL fica restrito ao security group dos backends. O RabbitMQ esta
disponivel para eles, mas o codigo atual do backend nao possui integracao AMQP.

## 4. Subir o monitoramento opcional

Depois que a stack principal estiver em `CREATE_COMPLETE`, crie outra stack
no CloudFormation, na mesma regiao, enviando `observabilidade-ti.yaml`.
Use um nome como `lamar-observabilidade-teste` e o mesmo `EnvironmentName`.
Essa stack nao substitui a principal e nao sobe os containers.

Na aba Resources da stack principal, obtenha os IDs fisicos e preencha:

| Parametro do monitoramento | Recurso logico na stack principal |
| --- | --- |
| `DatabaseInstanceId` | `DatabaseInstance` |
| `DatabaseVolumeId` | `DatabaseDataVolume` |
| `RabbitMqInstanceId` | `RabbitMqInstance` |
| `SwarmManagerInstanceId` | `SwarmManagerInstance` |
| `WebAz1InstanceId` | `WebInstanceAz1` |
| `WebAz2InstanceId` | `WebInstanceAz2` |
| `BackendAz1InstanceId` | `BackendInstanceAz1` |
| `BackendAz2InstanceId` | `BackendInstanceAz2` |

Para `LoadBalancerFullName`, copie do ARN de `ApplicationLoadBalancer`
somente a parte apos `loadbalancer/`, no formato `app/nome/id`.
Para `TargetGroupFullName`, copie do ARN de `WebTargetGroup` somente a parte
apos `targetgroup/`, no formato `nome/id`. Esses valores nao sao o DNS do ALB
nem os ARNs completos.

Informe `AlertEmail` se quiser receber alertas e confirme a assinatura pelo
link enviado pelo SNS. Vazio, o parametro cria apenas o topico, sem destinatario
de email. aguarde `CREATE_COMPLETE` e abra `DashboardUrl` na aba Outputs dessa stack.
As metricas podem demorar alguns minutos para aparecer.

Durante o teste com `t3.small`, acompanhe CPU e creditos de CPU no EC2/CloudWatch
e execute `sudo docker stats` nas duas VMs backend via bastion, usando seus
IPs privados. Observe consumo de memoria, reinicios e erros nos logs.
Memoria e uso dos containers nao aparecem automaticamente nas metricas EC2
desse painel; `docker stats` cobre essa verificacao manual.

## 5. Encerrar o ambiente

1. Interrompa o teste de carga e faca backup do banco se precisar dos dados.
   Excluir a stack principal tambem exclui o volume de dados MySQL.
2. Se criou a stack de observabilidade, exclua-a pelo CloudFormation e
   aguarde `DELETE_COMPLETE`.
3. Exclua a stack principal pelo CloudFormation e aguarde `DELETE_COMPLETE`.
   Se algum recurso ficar em `DELETE_FAILED`, leia o motivo nos eventos e
   resolva a dependencia antes de repetir a exclusao.
4. Confira se nao restaram recursos cobraveis da implantacao, especialmente
   NAT Gateways, Elastic IPs, EC2, ALB e EBS. Nao remova recursos de outras
   stacks ou ambientes.
5. Os parametros SSM criados pelos scripts em
   `/<EnvironmentName>/swarm/*` e `/<EnvironmentName>/database/ready` nao sao
   recursos gerenciados pelo template. Depois de confirmar que nenhuma
   stack usa esse prefixo, remova somente esses parametros no Parameter Store,
   incluindo o token de entrada no Swarm.

## Ingestao externa no Bronze: Ipeadata e Comex Stat

O template separado `buckets+lambda.yml` coleta as duas fontes por HTTPS e
grava as respostas JSON originais em pastas distintas. Nao converte para CSV,
nao altera valores, nao deduplica nem transforma os registros. Validar HTTP,
JSON e sucesso da consulta serve apenas para nao registrar uma falha como
dataset valido. O mesmo template cria buckets Bronze, Silver, Gold e de artefatos,
um job Glue de normalizacao e um database no Glue Data Catalog.
O bucket Gold fica reservado para uso futuro, sem carga ou processamento.
Athena nao e provisionado.
Uma carga inicial obrigatoria coleta as duas fontes e executa o Glue antes
de permitir que esta stack de dados conclua sua criacao.
Cada nova stack tem recursos de dados proprios, sem reutilizar buckets de
outra stack e sem depender de upload previo de script.

### Fontes e recortes

- Ipeadata: a pagina `https://ipeadata.gov.br/ExibeSerie.aspx?serid=31924`
  corresponde a `BM_ERV`, taxa anual media de cambio comercial de venda.
  A coleta salva toda a serie disponivel, inclusive valores ausentes,
  usando `https://www.ipeadata.gov.br/api/odata4/Metadados('BM_ERV')/Valores`.
- Comex Stat: os filtros foram recuperados de
  `https://api-comexstat.mdic.gov.br/filter/162584`. A consulta salva e de
  **importacao**, com os NCMs `84271011`, `84272010`, `84271019`, `84279000`,
  `84312011` e `84312019`, detalhamento mensal por NCM, pais e UF e metricas
  FOB, quilograma liquido e quantidade estatistica.
- O coletor usa o POST `/general?language=pt` da
  [API oficial](https://api-comexstat.mdic.gov.br/docs), sem abrir navegador,
  clicar em Consultar ou resolver CAPTCHA. O CSV do botao verde e produzido
  no navegador; o Bronze recebe o JSON bruto da API, nao uma reproducao
  byte a byte desse CSV.
- `ComexYears=25` significa 25 anos-calendario incluindo o ultimo ano
  publicado. Com dados disponiveis ate setembro/2026, o intervalo e
  janeiro/2002 a setembro/2026. O endpoint `/general/dates/updated` determina
  o limite, evitando pedir meses futuros. A consulta original 2000-2026
  cobre 27 anos e foi intencionalmente substituida pela janela de 25 anos.
- Os seis NCMs ficam no parametro `ComexNcmCodes`; mudancas futuras no link
  salvo nao alteram silenciosamente os filtros da Lambda. Para mudar o
  recorte, atualize o parametro. Coletar todos os produtos do Brasil seria
  outra escala de dados e nao faz parte desta configuracao.

### Criar a stack e executar

Crie uma stack separada no CloudFormation enviando `buckets+lambda.yml`.
Se ja utiliza esse template, revise o change set: esta versao substitui o
upload HTTP pela coleta e remove a Function URL publica e o output
`UploadApiEndpoint`. Nao e mais possivel enviar arquivos pelo endpoint antigo.
Os quatro buckets criados pelo template tem politica de retencao. Seus nomes
sao gerados pelo CloudFormation, com sufixos exclusivos; consulte os outputs.
Para outra implantacao independente, crie outra stack com outro nome.
Um update da mesma stack atualiza seus recursos, nao cria um ambiente novo.

Preencha os parametros:

| Parametro | Valor inicial |
| --- | --- |
| `LambdaRoleName` | `LabRole`, ou outra role existente autorizada |
| `GlueRoleName` | `LabRole`, ou outra role existente autorizada para Glue |
| `WorkflowRoleName` | `LabRole`, ou outra role existente autorizada para Step Functions |
| `InitialLoadRevision` | `1`; altere para solicitar nova carga inicial em um update |
| `ScheduleState` | `DISABLED`; desliga so o agendamento mensal, nao a carga inicial |
| `ScheduleExpression` | `cron(0 12 10 * ? *)`, dia 10 do mes as 12h UTC |
| `ComexYears` | `25` |
| `ComexNcmCodes` | Os seis codigos da consulta, ja preenchidos |

Nao existem mais parametros para informar buckets existentes ou URI de script.
Se atualizar uma stack da versao anterior, revise o change set: os antigos
buckets de nome fixo podem ser substituidos por novos, mantendo os antigos
retidos. Os dados anteriores nao sao copiados. As roles IAM continuam sendo
pre-requisitos externos, assim como no template principal da aplicacao.

A role precisa confiar em `lambda.amazonaws.com`, escrever objetos nos
prefixos `ipeadata/*`, `comexstat/*` e `_metadata/*` do Bronze, publicar o
script em `glue/*` no novo bucket de artefatos e publicar logs
no CloudWatch (`logs:CreateLogStream` e `logs:PutLogEvents`). Se o bucket usa
uma chave KMS gerenciada pelo cliente, sao necessarias as permissoes KMS e
a key policy correspondentes. O usuario que implanta precisa poder passar
a role para Lambda e criar os recursos de S3, Logs, Lambda e EventBridge.
A Lambda nao usa VPC, evitando criar NAT Gateway para acessar essas APIs.

Durante a criacao, a carga inicial ja executa ambas as fontes e o Glue.
Para coletas adicionais depois de `CREATE_COMPLETE`, abra a funcao indicada
no output `IngestionFunctionName`. No console Lambda, utilize:

```json
{"source": "ipeadata"}
```

```json
{"source": "comexstat"}
```

Execute separadamente, confira o resultado, os logs e os objetos no S3.
Uma execucao bem-sucedida retorna bucket e chaves; uma falha gera erro real,
nao uma resposta HTTP 200 com mensagem de falha. Coletas manuais adicionais
nao executam Glue automaticamente. Depois de validar a carga inicial,
atualize `ScheduleState` para `ENABLED` se quiser recorrencia: a regra mensal
dispara uma invocacao independente para cada fonte, somente no Bronze.

### Carga inicial que bloqueia a conclusao da stack

Depois de criar os buckets e a Lambda de bootstrap, `PublishGlueScript`
publica automaticamente o script embutido no bucket de artefatos. O job
Glue so e criado depois de receber a URI retornada por essa publicacao.
Depois de provisionar funcoes, job Glue, catalogo e agendamento,
o recurso `InitialDataLoad` inicia um workflow **Step Functions Standard**:

```text
CloudFormation: InitialDataLoad em CREATE_IN_PROGRESS
  -> Lambda: Ipeadata -> Bronze + manifesto COMPLETE
  -> Lambda: Comex Stat -> Bronze + manifesto COMPLETE
  -> Glue: aguarda o job terminar com sucesso e publicar as duas tabelas Silver
  -> Callback SUCCESS para CloudFormation
  -> Stack pode atingir CREATE_COMPLETE
```

O Glue recebe explicitamente os dois manifestos gerados por esse workflow.
Assim, um snapshot antigo ou uma coleta concorrente nao satisfaz a carga
inicial por engano. O script aceita `--IPEADATA_MANIFEST` e
`--COMEXSTAT_MANIFEST` e esta embutido em
`Mappings.GlueScript.Silver.Code` do YAML. Esse bloco e a fonte unica do
codigo Glue: editar o bloco e atualizar a stack publica a revisao no S3,
sem arquivo `.py` externo ou comando `aws s3 cp`.

Sao adicionados uma Lambda de bootstrap, seu grupo de logs com retencao de
14 dias, uma state machine e dois recursos customizados CloudFormation
(publicacao de script e carga inicial). A funcao
de bootstrap inicia a orquestracao e retorna sem sinalizar sucesso antecipado;
o callback so ocorre no final do workflow. Isso evita manter uma Lambda
esperando um job Glue que pode durar mais que o limite de uma invocacao.

Cada coleta continua limitada a 5 minutos e o Glue a 15 minutos. O workflow
tem limite global de 2200 segundos; o recurso CloudFormation espera ate
2400 segundos (40 minutos), permitindo os timeouts e as respostas finais.
Se o callback nao chegar, CloudFormation falha por timeout, nunca assume
sucesso por ausencia de resposta.

**Qualquer falha impede a conclusao:** erro HTTP persistente, inclusive o
429 ja observado no Comex, falta de dados, IAM insuficiente, script ausente,
dependencia Glue indisponivel ou falha no Silver resultam em `FAILED`.
Com rollback habilitado, a stack pode entrar em `ROLLBACK_IN_PROGRESS`.
Nao ha fallback para dados antigos, nem opcao de ignorar uma das fontes.
As escritas nao sao transacionais: pode haver Bronze parcial ou uma tabela
Silver publicada antes de a outra falhar.

O bootstrap usa a role `LambdaRoleName`, que agora tambem precisa de
`states:StartExecution` na state machine e logs da funcao de bootstrap.
`WorkflowRoleName` precisa confiar em `states.amazonaws.com` e permitir:

- `lambda:InvokeFunction` nas funcoes de coleta e bootstrap.
- `glue:StartJobRun`, `glue:GetJobRun`, `glue:GetJobRuns` e
  `glue:BatchStopJobRun` para iniciar, acompanhar e tentar cancelar o job.

A role Glue continua com suas permissoes de S3, catalogo e logs. Se todos os
parametros usarem `LabRole`, essa role precisa confiar nos tres servicos:
Lambda, Glue e Step Functions. O usuario que implanta tambem precisa poder
criar/atualizar state machines e passar a role. O template nao cria nem
altera essas permissoes.

Acompanhe `InitialDataLoad` na aba Events e a execucao no console Step
Functions. O motivo de falha inclui o ARN da execucao quando o callback
consegue ser enviado. O historico contem a URL pre-assinada de callback do
CloudFormation: restrinja acesso ao historico e nao compartilhe o input.
Se callbacks ou a orquestracao falharem antes da resposta, investigue os
logs e os timeouts; nao envie SUCCESS manualmente para contornar a validacao.

Na conclusao, os outputs `InitialLoadWorkflowArn`, `InitialLoadExecutionArn`
e `InitialLoadGlueRunId` identificam a state machine e as execucoes.
Em updates, mudar os filtros, periodo, codigo Glue publicado ou
`InitialLoadRevision` atualiza o recurso customizado e solicita nova carga.
Mudar apenas o estado do agendamento nao solicita outra carga. Updates de
codigo/roles sem mudar essas propriedades nao garantem reexecucao; incremente
`InitialLoadRevision` quando quiser valida-los com uma carga nova.
Nao reutilize uma URL de callback antiga para executar manualmente o workflow.

Na exclusao do recurso customizado, ele responde sucesso sem iniciar coleta
nem apagar dados. Os buckets criados continuam retidos mesmo em rollback;
uma nova stack recebe outros nomes gerados e nao adota esses buckets
antigos. Revise os recursos retidos para controlar custos e preservar
dados necessarios. O catalogo/job podem ser removidos no rollback;
dados retidos no Silver nao significam que a tabela continua registrada.

**Custo:** criar esta stack agora executa duas coletas, um job Glue e
transicoes Step Functions, mesmo com `ScheduleState=DISABLED`. Nao ha
garantia de gratuidade. O agendamento mensal continua apenas no Bronze;
execucoes Silver posteriores podem ser manuais.

### Organizacao dos objetos e Glue

```text
Bronze/
  ipeadata/serie=BM_ERV/ingestion_date=AAAA-MM-DD/run_id=.../page-0001.json
  comexstat/consulta=162584/flow=import/ingestion_date=AAAA-MM-DD/run_id=.../response.json
  _metadata/ipeadata/...
  _metadata/comexstat/...
```

Cada resposta e salva com seus bytes originais. O prefixo `_metadata/` guarda
origem, parametros da consulta, horario UTC, tamanho e SHA-256, separado dos
dados para nao misturar esquemas no Glue. A Lambda retorna so as chaves,
portanto o arquivo nao passa pelo limite de payload de uma Function URL.

No Glue, leia separadamente `value` do JSON Ipeadata e `data.list` do Comex.
O job incluido ja extrai esses envelopes, inclusive JSON multilinha, e valida
o tamanho e o SHA-256 contra os metadados do Bronze antes de transformar.
As regras de normalizacao e publicacao estao descritas abaixo.

### Limites, falhas e custo

O CSV mostrado tem aproximadamente 4,5 MB e 30.515 linhas, mas a resposta
JSON pode ser maior. O coletor tem 512 MB de memoria, timeout de 300 segundos
e limite de 32 MiB por resposta. Esses sao limites de seguranca, nao medicao
do tempo da coleta completa na AWS. A consulta e montada dinamicamente sem
transformar os registros; se ela exceder o limite, a execucao falha e sera
necessario dividi-la por periodo ou mudar a estrategia de transferencia.

Na verificacao das fontes, uma consulta Comex de janeiro a setembro/2026
retornou JSON com sucesso, mas a tentativa seguinte para a janela de 25 anos
recebeu **HTTP 429**. Portanto, o rate limit e um risco real: o codigo respeita
`Retry-After` numerico de ate 60 segundos ou usa espera progressiva, com no
maximo tres tentativas. Tambem repete erros HTTP transitorios e falhas de rede.
Persistindo a falha, registra erro no CloudWatch e interrompe a execucao.
O sucesso da consulta completa de 25 anos ainda depende de a fonte aceitar
a requisicao; enquanto houver esse bloqueio, a carga inicial falhara e a
stack nao sera marcada como completa.

Invocacoes assincronas permitem uma repeticao da execucao; a entrega do
EventBridge tambem tem retries limitados. Isso nao garante exatamente uma
coleta: reexecucoes recebem outro `run_id` e geram snapshots novos. Falhas
parciais podem deixar objetos sem todos os metadados ou paginas; so considere
completa uma execucao com `manifest.json` de status `COMPLETE` em
`_metadata/<fonte>/ingestion_date=.../run_id=.../`. O manifesto so e gravado
depois dos dados e metadados de todas as paginas; use suas chaves como entrada
para o Glue, evitando snapshots incompletos. Nao ha DLQ nem alerta
por email configurado; monitore `Errors` e `Duration` no CloudWatch.
Logs sao retidos por 14 dias.

A [pagina de precos do Lambda](https://aws.amazon.com/lambda/pricing/)
informa franquia de um milhao de requisicoes e 400.000 GB-s mensais.
Com duas execucoes mensais de 512 MB que durem 300 segundos cada, seriam
aproximadamente **300 GB-s por mes**, antes de testes e retries.
E uma estimativa de consumo, nao garantia de custo zero: a franquia e
compartilhada com outras funcoes e depende das regras da conta.

S3 (armazenamento e requisicoes), CloudWatch, EventBridge, Glue e Athena
possuem cobranca e elegibilidade proprias; nao estao incluidos nessa conta.
Em particular, jobs Glue nao sao cobertos pela franquia do Lambda e o Athena
cobra dados lidos nas consultas. Configure um AWS Budget e confira Billing
antes de habilitar a rotina. Nao ha limite monetario automatico neste template.
O Bronze nao expira snapshots automaticamente; considere retencao conforme
o historico necessario, sem apagar dados ainda usados pelo Glue.

Para validacao local, com o ambiente de `cfn-lint` disponivel:

```powershell
cfn-lint ".\IaC_Grupo7\IaC CloudFormation\buckets+lambda.yml"
python ".\IaC_Grupo7\IaC CloudFormation\tests\bronze_ingestion_test.py"
```

## Glue: Bronze para Silver

O job `BronzeToSilverJob` usa **Python Shell 3.9, 0.0625 DPU**, timeout de
15 minutos, nenhuma repeticao automatica e uma execucao por vez. E uma
configuracao de baixa capacidade para os arquivos pequenos atuais, nao um
cluster Spark. As dependencias `numpy==1.26.4`, `pyarrow==14.0.2` e
`boto3==1.34.162` sao instaladas pelo Glue ao iniciar. O job nao usa VPC,
nao possui trigger mensal proprio. Ele e executado automaticamente pela
carga inicial Step Functions e pode ser executado manualmente depois.

### Implantar sem preparar buckets ou enviar scripts

1. Crie uma nova stack enviando apenas `buckets+lambda.yml`. Bronze, Silver, Gold
   e artefatos sao sempre buckets novos, privados e exclusivos dessa stack,
   com retencao em exclusao ou substituicao.
2. O codigo em `Mappings.GlueScript.Silver.Code` e publicado pela Lambda
   de bootstrap no bucket de artefatos em
   `glue/bronze_to_silver-<sha256>.py`. O hash versiona cada revisao.
   Falha na publicacao bloqueia a criacao do job e da stack; nao existe
   sucesso ficticio apontando para um script inexistente.
3. Confira `GlueRoleName`: a role precisa confiar em `glue.amazonaws.com`.
   Se usar a mesma `LabRole` da Lambda, ela precisa permitir ambos os
   servicos na trust policy. O template nao cria nem modifica roles.
4. A role Glue precisa de `s3:ListBucket` no Bronze, `s3:GetObject` nos dados,
   metadados e no script do bucket de artefatos, `s3:PutObject` nos prefixos `datasets/*`, `_rejected/*`
   e `_metadata/*` do Silver, acesso aos logs do Glue e permissoes
   `glue:GetDatabase`, `glue:GetTable`, `glue:CreateTable` e `glue:UpdateTable`
   no database/tabelas. Chaves KMS exigem as permissoes e key policies
   correspondentes. O usuario que implanta precisa de permissoes Glue e
   `iam:PassRole`, alem das permissoes da ingestao.
   Se o catalogo/localizacao estiver sob controle do Lake Formation, tambem
   conceda as permissoes Lake Formation de criacao/alteracao e acesso a dados;
   somente IAM pode nao ser suficiente nesse ambiente.
5. Revise o change set e acompanhe a carga inicial ate `CREATE_COMPLETE` ou
   `UPDATE_COMPLETE`. Confira tambem as permissoes Step Functions descritas
   acima; criar os recursos nao basta para a stack concluir.
   Consulte os outputs `BronzeBucketName`, `SilverBucketName`, `GoldBucketName`,
   `ArtifactsBucketName`, `GlueScriptS3Uri`, `SilverGlueJobName` e
   `SilverCatalogDatabase`.

### Executar o processamento

A primeira execucao e automatica durante a criacao da stack. Para execucoes
adicionais, confirme o manifesto `COMPLETE` da coleta Bronze e abra o job
indicado por `SilverGlueJobName` no console Glue, utilizando Run.
O argumento `--SOURCE` aceita:

| Valor | Comportamento |
| --- | --- |
| `all` (padrao) | Processa Ipeadata e Comex, separadamente |
| `ipeadata` | Processa somente a serie cambial |
| `comexstat` | Processa somente as importacoes |

Por exemplo, se o Comex ainda estiver bloqueado por HTTP 429 e so houver
manifesto Ipeadata, execute com `--SOURCE=ipeadata`. Uma fonte sem manifesto
completo gera falha explicita. No modo `all`, as duas fontes sao tentadas;
se uma falhar, a outra ainda pode ser publicada, mas o job termina com erro.
Nao existe transacao conjunta entre as duas tabelas.

Para cada fonte, uma execucao manual sem argumentos de manifesto seleciona
o manifesto com maior `LastModified` do S3. A carga inicial informa
`--IPEADATA_MANIFEST` e `--COMEXSTAT_MANIFEST` para fixar seus proprios
snapshots. Em ambos os casos, o job valida o status e garante que as chaves
pertencem ao mesmo snapshot.
Ele nao mistura paginas de execucoes diferentes e nao volta silenciosamente
para um snapshot antigo se o mais recente estiver invalido. A leitura dos
objetos e limitada a 32 MiB por objeto, como no coletor.

### Tratamentos e esquemas

As fontes permanecem separadas, sem conversao de USD para BRL e sem join.
Nomes de colunas sao padronizados; textos sao aparados, mas nomes de paises,
UFs e descricoes nao sao traduzidos nem convertidos para outros codigos.

| Tabela | Colunas de negocio no Silver |
| --- | --- |
| `ipeadata` | `serie_codigo`, `data_referencia`, `ano`, `taxa_cambio`, `nivel`, `territorio_codigo` |
| `comexstat` | `fluxo`, `data_referencia`, `ano`, `mes`, `ncm_codigo`, `ncm_descricao`, `pais`, `uf_produto`, `valor_fob_usd`, `quilograma_liquido`, `quantidade_estatistica` |

As duas tabelas tambem recebem `bronze_key`, `bronze_run_id` e `data_ingestao`
para rastreabilidade. As datas usam tipo `date`; ano/mes usam inteiros.
NCM permanece texto de oito digitos, preservando zeros a esquerda.
O mes Comex vira uma data de referencia no primeiro dia daquele mes.

`taxa_cambio` usa `decimal(38,30)` para preservar inclusive os pequenos
valores historicos em notacao cientifica. As tres metricas Comex usam
`decimal(38,6)`, sem conversao intermediaria para ponto flutuante. Numeros
negativos, nao finitos ou que exigiriam arredondamento/perda de precisao
sao rejeitados. Nao ha tentativa de adivinhar separadores decimais diferentes
do formato da API.

Valor cambial explicitamente `null` e preservado como ausente, nao como zero.
Ausencia do campo `VALVALOR` e erro de esquema. Datas, serie, NCM, dimensoes
obrigatorias e metricas invalidas sao enviadas para rejeitados com motivo e
chave Bronze; o objeto original continua intacto no Bronze.

Duplicatas identicas dentro do snapshot sao removidas e contadas no relatorio.
A chave Ipeadata e serie/data/nivel/territorio; a chave Comex e
fluxo/mes/NCM/pais/UF. Se registros da mesma chave tiverem conteudos diferentes,
todos os conflitantes sao rejeitados, sem escolher um vencedor arbitrario.

### Escrita, rejeitados e consultas

```text
Silver/
  datasets/ipeadata/snapshots/<processing_id>/data.parquet
  datasets/comexstat/snapshots/<processing_id>/data.parquet
  _rejected/<fonte>/processing_id=<id>/records.jsonl
  _metadata/<fonte>/processing_id=<id>/report.json
```

Cada fonte gera um Parquet com compressao Snappy e esquema explicito.
Para esse volume, nao ha particionamento por ano, evitando muitos arquivos
pequenos. Cada execucao tem um novo `processing_id`; snapshots anteriores
permanecem no S3. Nao ha exclusao nem expiracao automatica.

O relatorio registra manifesto Bronze, horario, registros aceitos, rejeitados
e duplicatas removidas. Rejeitados preservam o registro com o motivo; nao ha
arquivo de rejeitados quando a contagem e zero. Se todos os registros forem
invalidos, o job grava os rejeitados e um relatorio de falha, mas nao muda
a tabela anteriormente publicada.

Somente depois de escrever o Parquet, o job cria ou atualiza a tabela
`ipeadata` ou `comexstat` no database indicado por `SilverCatalogDatabase`.
A localizacao da tabela aponta apenas para aquele snapshot completo,
evitando somar repetidamente o historico em reprocessamentos. Nao e
necessario crawler nem `MSCK REPAIR TABLE`. Falha antes da publicacao preserva
a localizacao anterior. Se a publicacao ocorrer e a gravacao do relatorio
final falhar, o job reporta erro, mas a tabela ja pode apontar para dados
validos; confira o catalogo e os logs.

O Athena pode usar esse catalogo depois do primeiro processamento bem-sucedido.
Configure separadamente workgroup, permissoes e bucket de resultados, selecione
o database do output e consulte, por exemplo:

```sql
SELECT ano, SUM(valor_fob_usd) AS total_fob_usd
FROM comexstat
GROUP BY ano
ORDER BY ano;
```

Nao aponte um crawler para `datasets/` inteiro nem inclua todos os snapshots
em outra tabela: isso reintroduziria a duplicacao que a publicacao evita.
Os prefixos `_rejected/` e `_metadata/` nao fazem parte das tabelas analiticas.
Nao sao criados workgroup Athena, processamento Gold, trigger Glue mensal ou alarmes.
Os logs Python Shell ficam em `/aws-glue/python-jobs/output` e
`/aws-glue/python-jobs/error`, sem retencao gerenciada por este template.
Excluir a stack remove o job e o database do catalogo, mas preserva os quatro
buckets e seus objetos, incluindo os scripts publicados no bucket de
artefatos. A limpeza desses dados e uma acao manual separada.

### Custo e validacao do Glue

O job e executado na carga inicial e cada Run adicional utiliza cobranca
propria do Glue, nao a franquia do Lambda. A capacidade configurada e 0.0625 DPU;
15 minutos representariam 0.015625 DPU-h por execucao, sujeitos ao preco,
tempo efetivamente faturado e regras da regiao. Instalacao de dependencias,
logs, catalogo, S3 e consultas Athena tambem devem ser considerados.
Nao ha limite monetario nem garantia de gratuidade.

O job usa memoria de uma unica maquina; aumentar significativamente o volume
exige rever a capacidade ou migrar para Glue Spark. Reprocessar publica outro
snapshot e pode gerar novas versoes logicas dos dados; nao ha bookmarks
Python Shell nem garantia de processamento exatamente uma vez.

Para testar o Parquet real localmente, use um ambiente Python isolado com
as dependencias configuradas no job e PyYAML para ler o template:

```powershell
python -m venv .venv-glue-tests
.\.venv-glue-tests\Scripts\python.exe -m pip install numpy==1.26.4 pyarrow==14.0.2 boto3==1.34.162 PyYAML==6.0.2
.\.venv-glue-tests\Scripts\python.exe ".\IaC_Grupo7\IaC CloudFormation\tests\silver_glue_test.py"
.\.venv-glue-tests\Scripts\python.exe -m unittest discover -s ".\IaC_Grupo7\IaC CloudFormation\tests" -p "*_test.py"
```

Use Python 3.9 a 3.11 para esse conjunto de dependencias. Os testes cobrem
normalizacao, rejeitados, precisao decimal, integridade, selecao de manifestos,
Parquet/Snappy, publicacao do catalogo, manifestos fixos e bloqueio da
conclusao da stack em falhas da carga inicial. Eles nao executam jobs na AWS.

## Dados e credenciais

A VM de banco clona `https://github.com/EnzoServilha/Banco_Grupo7.git` em
`/opt/Banco_Grupo7` e importa `SCRIPT-Lamar-AutoPecas.sql`. A clonagem tenta
ate tres vezes, cada uma limitada a 120 segundos; conexao permanentemente
indisponivel com o GitHub interrompe o bootstrap na etapa `database-import`.
O script fixa o banco
`lamar`, por isso `DatabaseName` aceita apenas esse nome. Sao importadas tabelas,
permissoes e dados de demonstracao, incluindo `admin@teste.com`. A senha desse
administrador esta em hash no SQL: no primeiro deploy, o bootstrap substitui
esse hash por um BCrypt da senha informada em `AdminPassword`. Entre pelo
`ApplicationUrl` com `admin@teste.com` e essa senha; nao e `DatabasePassword`
nem `JwtSecret`. A mudanca de parametros em uma stack existente nao redefine
a senha na VM ja inicializada: o UserData roda apenas na criacao da instancia.
Revise/remova os dados de demonstracao e troque as credenciais antes de expor
a aplicacao para uso real. SMTP nao e configurado neste deploy.

A importacao so ocorre em banco sem tabelas. O commit importado fica registrado
em `/var/lib/mysql/.lamar-import-complete`, no EBS. Um banco com tabelas e sem
esse marcador bloqueia o bootstrap para evitar sobrescrever dados ou repetir
inserts; uma importacao parcial exige revisao manual, nao exclusao automatica.
O manager aguarda o parametro SSM `/<EnvironmentName>/database/ready` contendo
o ID da stack atual antes de subir os containers. O backend ja recebe IP,
nome, usuario e senha desse MySQL, sem precisar de uma nova imagem.
O bootstrap grava `zz-lamar-network.cnf` depois do `mysqld.cnf` padrao para
escutar na rede privada e confirma o `bind_address` antes de sinalizar sucesso.

Clonar o repositorio importa o SQL versionado, nao copia dados de outro servidor
MySQL. Alteracoes futuras no GitHub nao sao aplicadas automaticamente ao banco;
use migracoes para atualizar um banco existente. A clonagem usa a branch padrao
do repositorio no momento da criacao; para producao, fixe um commit revisado.

As senhas e a chave JWT chegam aos containers por Docker secrets, importados
pelo Spring via `configtree:/run/secrets/`. `NoEcho` mascara parametros no console,
mas nao protege valores presentes no UserData das VMs, inclusive `AdminPassword`.
Use somente credenciais de laboratorio e restrinja acesso a EC2,
CloudFormation e aos arquivos do manager. Para producao, prefira buscar os
segredos no Secrets Manager em vez de inclui-los no UserData.

## Diagnostico

Use o output `SwarmManagerSshCommand` para acessar o manager pelo bastion:

```bash
sudo docker node ls
sudo docker service ls
sudo docker service ps codetracker_backend --no-trunc
sudo docker service logs codetracker_backend --tail 100
sudo journalctl -u label-swarm-workers.service -n 100 --no-pager
sudo tail -n 100 /var/log/cloud-init-output.log
```

Para acompanhar o bootstrap antes da instalacao do Docker:

```bash
sudo cloud-init status --long
sudo tail -f /var/log/cloud-init-output.log
```

Falhas dos bootstraps aparecem nos eventos de `BootstrapWaitCondition`. Falhas
de prontidao da aplicacao continuam associadas a `SwarmManagerInstance`.
Teste offline da rotina compartilhada, em Bash com `cfn-lint` instalado:

```bash
bash "IaC_Grupo7/IaC CloudFormation/tests/bootstrap.test.sh"
```

Os testes simulam timeouts, recuperacao, janela esgotada, falha de instalacao e
falha de sinalizacao, sem acessar AWS nem aguardar os intervalos reais.

Evite compartilhar logs ou arquivos que contenham credenciais.

## Limites

- A automacao foi feita para criacao de uma stack nova. Mudar UserData ou a tag
  em uma stack existente nao garante reexecutar cloud-init nem atualizar os
  servicos automaticamente. Nao reutilize a WaitConditionHandle de uma criacao
  anterior em uma atualizacao; use uma stack nova para esta versao do bootstrap.
- O manager, o banco e o RabbitMQ sao unicos: duas AZs nao tornam esses servicos
  altamente disponiveis. Perder o manager impede novos agendamentos.
- O ALB usa HTTP. Configure HTTPS e cookies seguros antes de uso em producao.
- O SSH publico do bastion continua aberto no template; restrinja ao seu IP.
- Ha custos com oito EC2 (`t3.small` por padrao), dois NAT Gateways, ALB,
  EBS e IPs publicos.
- Excluir a stack tambem exclui o volume do banco: faca backup antes.

O arquivo `../docker-compose.yml` continua sendo o ambiente local; a stack
Swarm da AWS e gerada em `/opt/codetracker/stack.yml` no manager.