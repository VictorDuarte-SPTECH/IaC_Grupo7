# Deploy da aplicacao com CloudFormation e Docker Swarm

## Data lake (stack independente)

O template `buckets+lambda.yml` cria buckets privados Bronze, Silver, Gold e
Artifacts, upload HTTPS, ingestao Ipeadata/Comex e catalogacao Silver no Glue.
Para implantar essa stack separadamente:

```bash
aws cloudformation deploy --stack-name datalake-grupo7 \
  --template-file "IaC CloudFormation/buckets+lambda.yml"
```

Os nomes dos buckets sao gerados pelo CloudFormation com o nome da stack,
o identificador logico da camada e um sufixo unico, por exemplo
`codetracker-bronzebucket-<sufixo>`. Nao ha `BucketName` fixo no template:
o CloudFormation adapta o nome as regras do S3, inclusive letras minusculas.
Consulte `BronzeBucketName`, `SilverBucketName`, `GoldBucketName` e
`ArtifactsBucketName` nos Outputs
para obter os nomes efetivos; a ingestao e a limpeza usam essas referencias.
Atualizar uma stack que ainda usa os nomes antigos substitui os buckets.
Faca backup antes: nao ha migracao automatica dos dados para os novos buckets.

Durante a criacao, `InitialIpeaIngestion` chama a Lambda de ingestao,
baixa o historico da serie `BM_ERV` pela API oficial HTTPS do Ipeadata e
grava a lista de observacoes em
`ipeadata/BM_ERV/ingestion_month=AAAA-MM/run_id=<uuid>/data.json` no Bronze.
Essa e a serie da pagina `https://ipeadata.gov.br/ExibeSerie.aspx?serid=31924`:
taxa de cambio comercial de venda media, R$/US$, com **frequencia anual**.
A coleta mensal nao cria observacoes mensais inexistentes na fonte.
Comex Stat esta implementado, mas `EnableComex=false` por padrao devido a
manutencao da API. Para habilitar, atualize a stack com `EnableComex=true`.
`InitialComexIngestion` aguarda a carga Ipea e executa coleta e processamento
Comex antes de liberar a stack. Uma falha Comex nao e ignorada nem substituida
por dados ficticios: pode causar rollback e exclusao dos dados.

Parametros adicionais:

| Parametro | Padrao e finalidade |
| --- | --- |
| `ComexYears` | `25`, de 1 a 30 anos-calendario, incluindo o ultimo ano disponivel; nunca antes de 1997 |
| `ComexNcmCodes` | `84271011,84272010,84271019,84279000,84312011,84312019`, filtros herdados da consulta 162584 no commit de referencia |
| `InitialLoadRevision` | `3`; altere para repetir as cargas iniciais |
| `ScheduleExpression` | `cron(0 6 1 * ? *)`; cron EventBridge em UTC |
| `ScheduleState` | `ENABLED`; use `DISABLED` para suspender as coletas mensais |

A coleta Comex consulta `/general/dates/updated` da API
`https://api-comexstat.mdic.gov.br` para determinar o periodo disponivel e
envia POST para `/general?language=pt`, sem usar o link temporario da pagina.
O payload tem `flow=import`, `monthDetail=true`, filtro `ncm` com os codigos
configurados, detalhamentos `ncm`, `country`, `state` e metricas `metricFOB`,
`metricKG`, `metricStatistic`. A resposta fica em
`comexstat/consulta=162584/flow=import/ingestion_month=AAAA-MM/run_id=<uuid>/data.json`.
A API retornou HTTP 503 durante esta implementacao; o contrato de coleta foi
exercitado offline, mas a consulta completa ainda precisa ser confirmada
quando a fonte voltar. Reduza `ComexYears` se a resposta exceder 32 MiB;
nao ha divisao automatica da consulta, truncamento silencioso ou carga parcial.

A mesma Lambda inicia o Glue e aguarda o sucesso do job e a existencia de
ao menos um arquivo `.parquet` nao vazio no prefixo de saida do Silver
antes de liberar a criacao da stack. A verificacao percorre as paginas da
listagem e nao depende de `_SUCCESS`, que o Glue pode nao gerar.
Portanto, os dados
iniciais estao nas duas camadas quando a stack atinge `CREATE_COMPLETE`;
nao e necessario enviar arquivos manualmente. Falhas da API, de permissao
ou do Glue/catalogo fazem essa etapa falhar explicitamente e podem causar rollback.
O job Glue tem timeout de 10 minutos e a Lambda, de 15 minutos, incluindo
download e espera na fila. Se esse prazo esgotar, a Lambda solicita a parada
do job e registra falha, nao sucesso sem dados.

A regra EventBridge executa por padrao no **dia 1 de cada mes, as 06:00 UTC**
(03:00 em Brasilia). Coleta Ipea e, quando ativado, Comex com invocacoes
independentes da mesma Lambda. Cada uma executa todo o caminho Bronze,
Glue e Silver; a falha de uma nao impede a outra. O Glue processa uma
execucao por vez e enfileira a outra. A espera na fila conta no timeout da
Lambda. A entrega e a execucao assincrona possuem retries limitados; nao ha
garantia de exactly-once. Uma reexecucao cria outro snapshot completo.
Cada coleta baixa novamente o historico para incorporar novos valores e
revisoes; snapshots anteriores, inclusive do mesmo mes, sao preservados.
O Parquet fica em `<chave-original>.parquet/` no Silver.
Os prefixos `ipeadata/`, `comexstat/` e `_metadata/` sao reservados: o
`GlueStarterFunction` ignora esses eventos, pois o coletor controla o Glue.
O output `IpeaIngestionFunctionName` identifica a funcao para acompanhar
logs ou executar manualmente com `{"source":"ipeadata"}` ou
`{"source":"comexstat"}` (Comex exige `EnableComex=true`).
Em atualizacoes, altere `InitialLoadRevision` para repetir as cargas.
Mudancas no script Glue tambem repetem as cargas, usando seu hash.

### Integridade, qualidade e schemas Silver

Cada snapshot tem um manifesto `_metadata/<chave-original>.manifest.json`
no Bronze, escrito somente apos o objeto de dados, com status `COMPLETE`,
SHA-256, bytes, registros, fonte, URL, filtros, horario e identificador da
execucao. O coletor serializa o JSON recebido; decimais sao preservados como
texto, sem conversao intermediaria para float. Nao e copia byte a byte da
resposta HTTP. O Glue verifica hash, tamanho, contagem e identidade do
snapshot antes de processa-lo. Historicos do formato antigo continuam no S3,
mas nao sao entradas do novo fluxo sem manifesto.

| Tabela | Colunas de negocio |
| --- | --- |
| `ipeadata` | `serie_codigo:string`, `data_referencia:date`, `ano:int`, `taxa_cambio:decimal(38,30)`, `nivel:string`, `territorio_codigo:string` |
| `comexstat` | `fluxo:string`, `data_referencia:date`, `ano:int`, `mes:int`, `ncm_codigo:string`, `ncm_descricao:string`, `pais:string`, `uf_produto:string`, `valor_fob_usd:decimal(38,6)`, `quilograma_liquido:decimal(38,6)`, `quantidade_estatistica:decimal(38,6)` |

Ambas incluem `bronze_key:string`, `bronze_run_id:string` e
`data_ingestao:date`. NCM preserva oito digitos, inclusive zeros iniciais;
datas e precisao numerica sao verificadas sem arredondamento silencioso.
Campos opcionais Ipea podem ser nulos, inclusive cotacao explicitamente
nula; cotacao ausente e invalida. Registros invalidos sao separados.
Duplicatas identicas sao removidas; valores divergentes para a mesma chave
de negocio rejeitam os registros conflitantes, em vez de escolher um valor
arbitrario. A chave Ipea e serie/data/nivel/territorio; Comex usa
fluxo/data/NCM/pais/UF.

Os rejeitados ficam no Silver em `_rejected/<chave-original>` com motivo e
registro. `_metadata/<chave-original>.report.json` contem aceitos,
rejeitados, duplicatas removidas e estado de publicacao.
Se nenhum registro valido restar, o job falha e preserva a tabela anterior.
Se existirem validos, publica-os e registra os rejeitados no relatorio.
O script escreve o snapshot antes de atualizar a tabela externa no database
retornado por `SilverCatalogDatabase`; os dados anteriores nao sao
sobrescritos. A tabela aponta para o ultimo snapshot publicado com sucesso,
nao para todos os historicos. Athena pode consultar essas tabelas, mas seu
workgroup, bucket de resultados e permissoes nao sao criados pelo template.

O script Glue fica isolado no Artifacts, com nome baseado em SHA-256;
`GlueScriptS3Uri` identifica o script efetivamente usado. Nao foi adicionado
Step Functions: o fluxo permanece na Lambda, sem exigir trust ou permissoes
de mais um servico na `LabRole`.

Envie um arquivo CSV com cabecalho ou JSON (objeto ou lista de objetos) via
POST ao `UploadApiEndpoint` retornado pela stack, usando
`?filename=exemplo.csv` ou `?filename=exemplo.json`. O bucket Bronze tambem
aceita uploads diretos via S3. Cada novo arquivo com extensao `.csv` ou
`.json` dispara um job Glue: ele descarta linhas com campos nulos e linhas
duplicadas e grava Parquet no Silver, em `<chave-original>.parquet/`.
Arquivos de outros formatos permanecem apenas no Bronze. O bucket Gold fica
disponivel para etapas analiticas futuras; esta stack nao o preenche.
**Excluir a stack apaga permanentemente os quatro buckets e seus dados**,
inclusive versoes e marcadores de exclusao. Isso tambem vale para rollback
de criacao. Os buckets usam `DeletionPolicy: Delete` e
`UpdateReplacePolicy: Delete`. Uma Lambda de limpeza esvazia os buckets e
aborta uploads multipart pendentes antes da exclusao pelo CloudFormation.
Pare uploads externos e aguarde os jobs Glue em andamento terminarem antes
de excluir a stack, para evitar novas gravacoes durante a limpeza.
A limpeza tem limite de 15 minutos; erros de permissao, Object Lock ou
excesso de dados podem impedir a exclusao e exigem corrigir a causa e tentar
novamente. A stack reutiliza exclusivamente a `LabRole` existente para
as cinco Lambdas e o job Glue; nao cria nem altera roles ou politicas IAM e
nao requer `CAPABILITY_IAM`. A identidade do deploy precisa de `iam:PassRole`
para essa role, alem de permissoes para criar os recursos da stack.
A `LabRole` precisa permitir que Lambda e Glue a assumam, gravar logs,
ler/listar o Bronze, ler/listar/gravar/excluir objetos no Silver,
gravar objetos no Bronze e executar `glue:StartJobRun` no job criado.
A publicacao do script precisa de escrita/exclusao no Artifacts e o Glue,
de leitura do script. O deploy precisa de `glue:CreateDatabase` e
`glue:DeleteDatabase`; o job precisa de `glue:GetTable`, `glue:CreateTable`,
`glue:UpdateTable` e, conforme as politicas do catalogo, `glue:GetDatabase`.
Permissoes S3 abrangem tambem manifestos, rejeitados e relatorios.
Essas acoes precisam ja estar autorizadas na `LabRole`; o template nao as concede.
A ingestao tambem precisa de `glue:GetJobRun`, `glue:BatchStopJobRun` e
`s3:ListBucket` no Silver para verificar o resultado. O deploy precisa criar
as regras agendadas EventBridge e suas permissoes de invocacao Lambda.
Para a limpeza, a role tambem precisa de `s3:ListBucket`,
`s3:ListBucketVersions`, `s3:ListBucketMultipartUploads`, `s3:DeleteObject`,
`s3:DeleteObjectVersion` e `s3:AbortMultipartUpload` nos buckets/objetos
correspondentes. O CloudFormation precisa poder excluir os buckets.
Se o laboratorio nao conceder essas permissoes ou relacoes de confianca,
a troca no template nao as concede: solicite a adequacao ao responsavel
pelo laboratorio. Cada execucao Glue tambem gera custos.

Uma stack em `ROLLBACK_COMPLETE` precisa ser recriada, nao atualizada.
Antes de tentar novamente, confira os buckets preservados pela tentativa
anterior com a versao antiga do template, que usava nomes fixos por
conta/regiao. Os novos nomes gerados nao reutilizam esses buckets.
A limpeza nova nao remove buckets orfaos de stacks
anteriores nem muda stacks que ainda usam o template antigo.
Preserve os dados e planeje a importacao dos buckets ou nomes diferentes
antes de recriar a stack; nao exclua buckets com dados para contornar o erro.

Os contratos offline da ingestao podem ser executados sem acessar a AWS:
`python -m unittest discover -s "IaC CloudFormation\tests" -p ipea_ingestion_test.py`.
Schemas, qualidade e catalogacao:
`python -m unittest discover -s "IaC CloudFormation\tests" -p silver_dataset_test.py`.

O template `cloudformationCodeTracker.yaml` instala Docker nas VMs da
aplicacao, MySQL principal na AZ2 e MySQL de recuperacao na AZ1. As EC2
exclusivas do RabbitMQ foram removidas: cada worker backend executa seu broker local.
A copia do banco a cada 12 horas e o
failover para AZ1 sao automaticos. O unico manager, na AZ1, inicializa o
cluster e fica em `Drain`. O manager AZ2 foi retirado para teste.
O manager AZ1 descobre quatro workers, aplica
labels e executa `docker stack deploy`.

| Funcao | AZ1 | AZ2 |
| --- | --- | --- |
| Manager Swarm | 1, `Drain`, subnet web privada | 0 |
| Worker web | 1 frontend | 1 frontend |
| Worker backend (`t3.medium`) | 2 replicas backend + 1 etiquetas + 1 RabbitMQ | 2 replicas backend + 1 etiquetas + 1 RabbitMQ |
| MySQL | 1 standby | 1 principal |
| Bastion | 1 | 0 |

Total padrao: **8 EC2, cinco nos Swarm (um manager e quatro workers)** e oito
containers da aplicacao (dois frontend, quatro backend e dois etiquetas).
Os dois brokers sao containers Docker locais adicionais, fora da stack Swarm,
com volume nomeado `rabbitmq-data`; nao sao tarefas agendadas pelo Swarm.
Cada backend tem quatro containers: dois backend, um etiquetas e um RabbitMQ.
O total e dez containers, incluindo os dois brokers. Nao existem mais workers
`tier=rabbitmq` nem parametro de ativacao das EC2 exclusivas.
Ha duas AZs na mesma regiao AWS, nao duas regioes.

O manager compartilha a subnet web privada AZ1 com o frontend, mas usa
somente `PrivateSshSecurityGroup` e `SwarmSecurityGroup`, sem IP publico nem
`WebSecurityGroup`. A comunicacao com os workers usa a rota local da VPC.

| Subnet privada | CIDR | EC2 previstas | IPs livres previstos |
| --- | --- | --- | --- |
| Web AZ1 | `10.0.0.64/28` | Frontend e manager AZ1 | 9 |
| Web AZ2 | `10.0.0.80/28` | Frontend | 10 |
| Backend AZ1 | `10.0.0.96/28` | Backend/etiquetas/RabbitMQ e MySQL standby | 9 |
| Backend AZ2 | `10.0.0.112/28` | Backend/etiquetas/RabbitMQ e MySQL principal | 9 |

Cada `/28` tem 11 IPs utilizaveis apos as reservas AWS. Essa contagem considera
somente as EC2 previstas; IPs individuais continuam atribuidos pela AWS.
Mudar a subnet de uma EC2 existente exige substituicao. Nao aplique essa
mudanca diretamente ao manager de um cluster em uso sem um plano de
migracao e preservacao do estado Swarm; o bootstrap da AZ1 inicializa um cluster.

**O manager AZ1 e um ponto unico de falha do controle.** Perde-lo impede
alteracoes e novos agendamentos, embora tarefas existentes possam continuar
executando. Nao ha standby de manager nesta configuracao de teste.
Para tolerar a perda de um manager, use tres; para tolerar a perda de qualquer
AZ, distribua os tres em tres AZs. O lider e eleito pelo Swarm.
Se um cluster existente ja tiver dois managers, nao exclua simplesmente a
EC2 AZ2: a mudanca de participacao precisa ser feita com quorum disponivel,
demovendo o manager a retirar antes de remove-lo. A remocao do recurso no
CloudFormation nao executa essa democao. Para o teste, prefira uma stack nova
e preserve os dados antes de substituir qualquer ambiente existente.

## 0. Preparar o ambiente

Este roteiro sobe a infraestrutura AWS pelo console do CloudFormation.
Nao e necessario executar os projetos Terraform, LocalStack ou o Compose
local para este deploy. O template principal cria a rede, oito EC2 por padrao, dois NAT
Gateways, ALB, dois volumes de banco, DNS privado e o cluster Swarm.
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
   Confira cotas e permissoes para oito EC2: quatro `t3.micro` (dois bancos e
   dois frontends), duas `t3.small` (bastion e manager) e duas `t3.medium`
   (backends compartilhados com etiquetas e RabbitMQ), dois NAT Gateways,
   tres Elastic IPs, ALB, VPC, EBS, SSM, Route 53 e CloudFormation.
5. Em EC2 > Key pairs, crie ou selecione um par de chaves na mesma regiao.
   Guarde o arquivo privado `.pem`: ele sera usado no acesso pelo bastion.
6. Confira o instance profile que sera associado as VMs, como
   `LabInstanceProfile`, e as permissoes descritas no passo 2. O template
   nao cria esse perfil.
7. Separe senhas distintas para banco, administrador, RabbitMQ e SMTP, alem da
   chave JWT Base64. Informe a conta SMTP e o destinatario das etiquetas.
   O exemplo de geracao da chave no passo 2 usa PowerShell,
   sem instalar dependencias.
   Nao salve esses valores no repositorio.

**Atencao:** os recursos geram custos enquanto existirem, inclusive sem
acessos. As VMs backend usam `t3.medium` (4 GiB) e compartilham recursos com
etiquetas e RabbitMQ; confirme capacidade com teste de carga e metricas.
Use dados de laboratorio: o template usa HTTP, importa dados de demonstracao
e inclui segredos no UserData, conforme as limitacoes ao final.

## 1. Conferir as imagens publicadas

Abra o terminal Bash no diretorio que contem as pastas dos repositorios.
Com Docker em execucao, execute:

```bash
bash IaC_Grupo7/publicar-dockerhub.sh guilhermebarros297 <nova-tag>
```

O template usa por padrao as imagens ja publicadas como `v1.0.1` no namespace
`guilhermebarros297` (backend, etiquetas e frontend). Confira as tres tags no
Docker Hub antes do deploy. Elas precisam ser publicas e Linux amd64. O
frontend usa `/api` em producao, nao `localhost:8080`.

Para publicar outra versao, use o comando acima com uma tag nova e configure
`ApplicationImageTag` com essa mesma tag. O script solicita login no Docker
Hub, constroi e publica as tres imagens. Nao inclua senhas ou a chave JWT nas
imagens: elas sao fornecidas na criacao da stack.

## 2. Criar uma stack nova

Esta versao altera a topologia e foi preparada para uma stack nova. Atualizar
somente o template de uma stack existente nao garante instalar a AWS CLI,
instalar os brokers nos backends, configurar o manager unico ou atualizar as
replicas. Nao execute uma atualizacao em uso presumindo que o UserData sera
reexecutado. Planeje migracao e backup do banco, das filas e dos volumes
antes de substituir o ambiente; nao exclua a stack com dados a preservar.
Se os ambientes coexistirem, use outro `EnvironmentName` para evitar colisao
dos parametros SSM. Nenhuma migracao automatica de mensagens foi adicionada.

**RabbitMQ consolidado nos backends:** `EnableRabbitMq` nao existe mais.
`RabbitMqPassword` volta a ser obrigatorio, com ao menos 12 caracteres.
Os Outputs RabbitMQ foram preservados, mas agora apontam para os IPs dos
backends AZ1/AZ2 e seus tuneis SSH, nao para EC2 dedicadas.
Antes de excluir as EC2 RabbitMQ antigas, interrompa produtores e consumidores
e preserve mensagens, definicoes e dados dos volumes locais conforme a estrategia
de migracao escolhida. Exportar definicoes nao exporta as mensagens das filas.
Nao ha transferencia automatica do volume `rabbitmq-data` entre os hosts.
Excluir a EC2 pode apagar permanentemente seus dados; nao apague antes de
confirmar a preservacao necessaria. Mudar UserData ou o tipo da EC2 nao garante
instalar o broker nos backends existentes: planeje a migracao ou use stack nova.

1. Na regiao escolhida, abra CloudFormation > Stacks > Create stack >
   With new resources (standard).
2. Selecione Choose an existing template > Upload a template file e envie
   `cloudformationCodeTracker.yaml`, localizado nesta pasta. Nao envie
   `observabilidade-ti.yaml` nesta etapa.
3. Avance e informe um nome de stack, por exemplo `lamar-app-teste`.
   O nome da stack e diferente de `EnvironmentName`, que prefixa os recursos.
4. Preencha os parametros abaixo. Mantenha `InstanceType=t3.small`,
   `BackendInstanceType=t3.medium`,
   `DatabaseInstanceType=t3.micro` e `FrontendInstanceType=t3.micro` para
   usar o dimensionamento atual.
5. Em Configure stack options, mantenha o rollback automatico e as demais
   opcoes padrao, salvo exigencias do seu ambiente. Se usar uma service role
   do CloudFormation, ela precisa ter permissao para criar os recursos e
   associar o instance profile.
6. Revise os parametros, avance e selecione Submit/Create stack.

Parametros a preencher:

- `EnvironmentName`: `lamar-auto-pecas`, ou outro prefixo exclusivo para
  esta implantacao, com ate 25 caracteres, letras, numeros e hifens.
- `DockerHubNamespace`: `guilhermebarros297`.
- `ApplicationImageTag`: `v1.0.1` para as tres imagens publicadas.
- `KeyName`: um par de chaves EC2 existente na regiao.
- `InstanceProfileName`: um perfil IAM existente, por exemplo `LabInstanceProfile`.
- `UbuntuAmiId`: mantenha o parametro SSM padrao do Ubuntu 24.04 amd64,
  desde que disponivel na regiao.
- `DatabaseName`, `DatabaseUser` e `RabbitMqUser`: mantenha `lamar` para
  este roteiro; `DatabaseName` obrigatoriamente deve ser `lamar`.
- `DatabasePassword`: senha com pelo menos 12 caracteres.
- `RabbitMqPassword`: obrigatoria para os dois brokers; use senha
  distinta da senha do banco, com pelo menos 12 caracteres.
- `AdminPassword`: senha inicial de 12 a 72 caracteres para `admin@teste.com`,
  distinta da senha do MySQL. O bootstrap aplica um hash BCrypt ao administrador
  importado e falha se o usuario ativo com `ROLE_ADMIN` nao existir.
- `JwtSecret`: chave aleatoria codificada em Base64 que represente ao menos
  32 bytes (256 bits), nao uma senha de usuario nem um token JWT.
  O comando PowerShell tambem aparece na descricao desse parametro na tela
  de criacao da stack. Execute-o localmente e cole somente a chave gerada;
  o console CloudFormation nao executa comandos. Gere uma nova no PowerShell:

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
- `MailUsername`: conta de e-mail SMTP que envia e-mails do backend e etiquetas.
- `MailPassword`: senha SMTP dessa conta (senha de app no Gmail); a senha
  antiga presente em imagens anteriores deve ser revogada.
- `EtiquetaEmailDestinatario`: e-mail que recebera as etiquetas geradas.
- `InstanceType`: `t3.small` por padrao, somente manager e bastion.
- `BackendInstanceType`: `t3.medium` por padrao, nos dois workers backend.
  Cada VM tem 4 GiB de RAM e duas vCPUs. Hospeda duas replicas Java de 768 MiB,
  um etiquetas de 512 MiB e um RabbitMQ com limite de 1 GiB. Os limites somam
  3 GiB, deixando aproximadamente 1 GiB para SO e Docker; valide sob carga.
  O watermark de memoria do RabbitMQ e 512 MiB, abaixo do limite do container.
  Pressao de memoria pode bloquear produtores; nao e garantia contra OOM ou
  falta de disco. Mais containers nao aumentam a capacidade de CPU da instancia.
- `DatabaseInstanceType`: `t3.micro` por padrao, para MySQL principal e standby.
  Cada instancia tem 1 GiB de RAM. Valide o consumo do MySQL, consultas e
  restauracoes; pouca memoria pode causar OOM e indisponibilidade. Os volumes
  de dados continuam gp3 de 20 GiB; reduzir a EC2 nao reduz esses volumes.
- `FrontendInstanceType`: `t3.micro` por padrao, somente para `WebInstanceAz1`
  e `WebInstanceAz2`. O manager na subnet web AZ1 continua usando
  `InstanceType`; o limite de memoria de cada container frontend e 128 MiB.

Nos defaults, sao quatro `t3.micro`, duas `t3.small` e duas `t3.medium`.
Todos esses tipos possuem duas vCPUs: o total permanece 8 EC2 e 16 vCPUs.
Os brokers nao exigem IPs VPC nem EC2 adicionais; o manager AZ2 continua ausente.
Isso nao comprova a causa de `NotStabilized` nem garante atender aos limites
do laboratorio; considere tambem instancias de outras stacks e regioes.

Use uma regiao com ao menos duas zonas de disponibilidade e acesso ao parametro
SSM da AMI Ubuntu. O perfil das VMs precisa permitir `ssm:PutParameter` e
`ssm:GetParameter` em `/<EnvironmentName>/swarm/*`, `kms:Decrypt` para ler o
SecureString com a chave usada pelo SSM e `cloudformation:SignalResource` na
stack. Tambem sao necessarias `ssm:PutParameter` e `ssm:GetParameter` em
`/<EnvironmentName>/database/ready` e `/<EnvironmentName>/database/standby-ready`.
Os workers backend consultam SSM e descriptografam o token de worker.
Esta versao nao publica token de ingresso de manager. Restrinja o acesso ao
token de worker e nao o publique em logs.
Para instalar e operar a recuperacao automatica, esse perfil tambem precisa:

| Permissao | Escopo necessario |
| --- | --- |
| `cloudformation:DescribeStackResource` | Stack principal, para baixar o agente incluido no Metadata |
| `ec2:DescribeInstances` | `*`, para consultar o estado do banco AZ2 |
| `ec2:StopInstances` | Somente a instancia fisica de `DatabaseInstance` |
| `route53:ChangeResourceRecordSets` | Hosted zone privada `DatabasePrivateHostedZone` |
| `route53:GetChange` | Alteracoes Route 53, recurso `arn:aws:route53:::change/*` |

O template nao amplia as permissoes do instance profile existente. Configure-as
antes de considerar o failover operacional; perfis de laboratorio podem ter
restricoes que impedem essas acoes. A identidade que cria a stack precisa
poder criar a hosted zone privada e associar o instance profile. Para
restringir permissoes por recurso, use os IDs/ARNs da aba Resources da stack.

### Acompanhar a criacao

Na aba Events, acompanhe os recursos ate a stack atingir `CREATE_COMPLETE`.
O bootstrap pode levar dezenas de minutos; os sinais iniciais e a prontidao
do manager tem prazo de ate 60 minutos a partir da criacao de cada recurso.
Uma EC2 em estado `running` nao significa que a aplicacao esta pronta.

O processo e automatico: instala Docker, forma o Swarm, prepara MySQL e
RabbitMQ nos backends, importa o banco e publica os servicos. Nao execute `docker compose up`
nem `docker swarm init` manualmente nas VMs.

Se houver `CREATE_FAILED` ou `ROLLBACK_IN_PROGRESS`, localize na aba Events
o primeiro recurso com falha e consulte a secao Diagnostico. Corrija a causa
antes de tentar novamente; nao trate uma stack em rollback como implantada.
Se houver dados a preservar, faca backup antes de excluir qualquer stack.

### O que acontece durante o bootstrap

O manager AZ1 publica `/<EnvironmentName>/swarm/stack-id` somente depois do IP,
do token de worker e da criacao dos secrets. Os workers so usam
esses parametros quando o marcador corresponde
ao ID da stack atual, evitando entrada em um cluster de uma implantacao antiga.
Nao execute stacks simultaneas com o mesmo `EnvironmentName` na mesma regiao.
Cada backend inicia seu RabbitMQ e aguarda saude antes de entrar como worker.
Falhas do broker sinalizam a etapa `rabbitmq-start`. Sao esperados quatro
workers e etiquetas usa `tier=backend`, uma replica em cada backend.
Os oito bootstraps usam `Mappings.Bootstrap`:

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
Isso inclui bastion, manager AZ1, dois workers web, dois backends com RabbitMQ
e os dois bancos. Nao ha sinal de EC2 RabbitMQ separada.
O banco AZ1 so sinaliza
sucesso depois de receber e restaurar o primeiro dump do principal.
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
aguarda ate 10 minutos pelos quatro workers antes de sinalizar falha.
Depois, aguarda ate 15 minutos pelo banco
e pela primeira copia na AZ1, e 15 minutos pelas replicas e respostas HTTP.
Falhas definitivas sao sinalizadas
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
sudo docker service ps codetracker_etiquetas --filter desired-state=running
sudo docker service inspect codetracker_backend --format '{{.Spec.EndpointSpec.Mode}}'
```

Devem aparecer cinco nos no Swarm: um manager AZ1 em `Ready`/`Drain`
e `Leader`, e quatro workers
em `Ready`/`Active`. Os servicos devem mostrar backend `4/4`, frontend `2/2`
e etiquetas `2/2`. Na lista de tarefas do backend, confira duas em
`backend-az1` e duas em `backend-az2`; o modo de endpoint deve ser `vip`.
Etiquetas deve ter uma tarefa em `backend-az1` e outra em `backend-az2`.
Em cada backend, `sudo docker ps` tambem deve mostrar o broker local saudavel;
ele nao aparece em `docker service ls`, pois esta fora da stack Swarm.
O limite de uma replica por no impede concentrar ambas no host sobrevivente;
se um host ficar indisponivel, uma replica pode ficar pendente.
Se isso nao ocorrer, consulte os logs antes de iniciar o teste de carga.

O fluxo de acesso fica assim:

```text
Navegador -> ALB :80 -> frontend/Nginx nas VMs web
                     -> /api/ -> VIP do backend -> 4 replicas :8080 na rede overlay
                     -> /etiquetas-api/ -> 2 etiquetas :8081 nas VMs backend, via overlay
Backend -> database.<EnvironmentName>.internal:3306 -> MySQL AZ2
                                                       -> AZ1 apos failover
MySQL AZ2 -> dump automatico a cada 12h -> MySQL AZ1 (somente leitura)
Backend -> IP privado do backend AZ1 ou AZ2 :5672 -> RabbitMQ local (brokers independentes)
Etiquetas -> backend :8080 na rede overlay
```

Ha duas replicas de frontend, uma por VM web, quatro de backend, duas por VM
backend, duas de etiquetas e dois brokers locais, um de cada por VM backend. O Nginx do frontend encaminha
cada requisicao `/api/` ao VIP do servico backend; o Swarm distribui as
conexoes entre as quatro replicas por round-robin (nao e afinidade por usuario).
O ALB distribui as conexoes externas entre os dois frontends. O manager fica
em modo drain.
Na stack Swarm, somente a porta do frontend e publicada; backend e etiquetas
sao internos. Os brokers locais publicam AMQP em 5672, restrito ao Security Group
backend, e administracao somente em `127.0.0.1:15672`, via tunel SSH.
O acesso MySQL fica restrito aos backends e a comunicacao entre os bancos
necessaria ao dump. Os dois RabbitMQ ficam acessiveis pelos backends.
Backend (producer) e etiquetas (consumer) recebem os dois IPs em
`SPRING_RABBITMQ_ADDRESSES` e usam Spring AMQP. Os brokers nao formam cluster:
filas, mensagens e definicoes de um nao sao copiadas para o outro. Se o
producer publicar em um broker e o consumer estiver conectado apenas ao outro,
a mensagem aguardara no primeiro. Conectar ao segundo broker nao recupera as
mensagens do primeiro; planeje uma topologia compartilhada antes de depender
de failover entre os brokers.

### Recuperacao automatica do MySQL

Nao ha etapa manual para gerar dumps ou ativar a AZ1. O funcionamento e:

1. No bootstrap, a AZ1 aguarda o banco AZ2 pronto, baixa um dump completo de
   `lamar`, restaura e valida tabelas antes de liberar a aplicacao.
2. O timer `codetracker-database-backup.timer` repete a copia diariamente as
   00:00 e 12:00 UTC. O dump usa transacao consistente para tabelas InnoDB;
   nao execute mudancas de schema durante a copia. O standby fica somente
   leitura fora da restauracao. O snapshot anterior valido e preservado se
   download, importacao ou validacao falharem.
3. O timer `codetracker-database-failover.timer` verifica o MySQL AZ2 a cada
   30 segundos, consultando a tabela de usuarios. Depois de tres falhas
   consecutivas, o agente verifica o MySQL local e a existencia de um dump.
4. O agente solicita o desligamento da EC2 AZ2 e so prossegue quando a AWS
   confirma `stopped` ou `terminated`. Isso impede que o banco antigo e o novo
   recebam escritas ao mesmo tempo. Sem confirmacao ou permissao IAM, a
   promocao e bloqueada e o erro fica no journal; o monitor tenta novamente.
5. A AZ1 restaura o ultimo dump valido, valida, habilita escrita e atualiza
   o registro privado `DatabaseEndpoint` para seu proprio IP. Os quatro
   backends usam esse nome, com TTL DNS de 10 segundos e cache Java limitado
   a 10 segundos; o pool JDBC descarta conexoes quebradas e abre novas.

Ha interrupcao durante deteccao, desligamento, restauracao e propagacao DNS.
Requisicoes em andamento podem falhar: nao sao repetidas automaticamente,
para evitar duplicar operacoes de escrita. As novas conexoes passam a usar
a AZ1 sem editar parametros ou reimplantar os containers.
Isso nao garante recuperacao de toda a aplicacao numa queda completa de AZ.

A perda esperada e de ate aproximadamente 12 horas, mais o tempo da copia.
Falhas nos dumps podem tornar o ultimo snapshot mais antigo; monitore a data
de `last-backup` e os logs. Os dumps `latest.sql` e `previous.sql`, o estado
de promocao e o MySQL standby ficam no EBS criptografado da AZ1. Dimensione
os 20 GiB para banco, dumps e arquivo temporario; nao e backup externo nem
historico de longo prazo.

Depois da promocao, o agente para de copiar dados da AZ2 e nao retorna a ela
automaticamente. Nunca reinicie o banco antigo como principal: ele estara
desatualizado. Retomar a redundancia exige reconstruir um standby a partir
do banco ativo, sem sobrescrever os dados novos da AZ1.

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
| `DatabaseStandbyInstanceId` | `DatabaseStandbyInstance` |
| `DatabaseStandbyVolumeId` | `DatabaseStandbyDataVolume` |
| `SwarmManagerInstanceId` | `SwarmManagerInstance` |
| `WebAz1InstanceId` | `WebInstanceAz1` |
| `WebAz2InstanceId` | `WebInstanceAz2` |
| `BackendAz1InstanceId` | `BackendInstanceAz1` |
| `BackendAz2InstanceId` | `BackendInstanceAz2` |

Nao existem parametros de IDs RabbitMQ nesta versao. Seus hosts sao os mesmos
`BackendAz1InstanceId` e `BackendAz2InstanceId`; o painel os identifica como
backend + etiquetas + RabbitMQ, sem duplicar metricas ou alarmes EC2.

Para `LoadBalancerFullName`, copie do ARN de `ApplicationLoadBalancer`
somente a parte apos `loadbalancer/`, no formato `app/nome/id`.
Para `TargetGroupFullName`, copie do ARN de `WebTargetGroup` somente a parte
apos `targetgroup/`, no formato `nome/id`. Esses valores nao sao o DNS do ALB
nem os ARNs completos.

Informe `AlertEmail` se quiser receber alertas e confirme a assinatura pelo
link enviado pelo SNS. Vazio, o parametro cria apenas o topico, sem destinatario
de email. aguarde `CREATE_COMPLETE` e abra `DashboardUrl` na aba Outputs dessa stack.
As metricas podem demorar alguns minutos para aparecer.

Durante o teste com `t3.medium`, acompanhe CPU e creditos de CPU no EC2/CloudWatch
e execute `sudo docker stats` nas duas VMs backend via bastion, usando seus
IPs privados. Observe consumo de memoria, reinicios e erros nos logs.
Memoria e uso dos containers nao aparecem automaticamente nas metricas EC2
desse painel; `docker stats` cobre essa verificacao manual.

### Cobertura operacional e data lake

O painel principal inclui creditos CPU das sete EC2 privadas.
Os alarmes MySQL continuam ativos. O status das EC2 compartilhadas com RabbitMQ
e coberto pelos alarmes de backend, nao pelo estado dos processos. Um alarme adicional
acompanha os status checks do manager AZ1, dos dois workers web e dos dois
workers backend. Informe `BastionInstanceId` com o ID fisico de
`BastionInstance` para habilitar o alarme do bastion.
Nao e necessario informar ID de manager AZ2 nesta versao da observabilidade.
Status checks EC2 nao comprovam quorum nem saude do servico Docker.
Tambem ha alertas para nenhum frontend saudavel no ALB (inclusive ausencia
de telemetria por dois minutos) e latencia p95 acima de 2 segundos em
3 de 5 minutos, ignorando percentis com poucas amostras.
Os novos alarmes de EC2 e saude/latencia do ALB notificam a recuperacao por SNS.
O painel de creditos CPU nao implica alarme de CPU ou de creditos baixos.

Para monitorar o data lake, primeiro implante a versao atualizada de
`buckets+lambda.yml`, que adiciona Outputs e metricas de ingestao.
Atualize/crie `observabilidade-ti.yaml` na mesma conta e regiao, com um
`EnvironmentName` que nao conflite com outro painel/topico existente.
Copie os nomes fisicos dos Outputs do data lake para estes parametros:

| Parametro da observabilidade | Output do data lake |
| --- | --- |
| `IpeaIngestionFunctionName` | `IpeaIngestionFunctionName` |
| `UploadFunctionName` | `UploadFunctionName` |
| `GlueStarterFunctionName` | `GlueStarterFunctionName` |
| `ScriptPublisherFunctionName` | `ScriptPublisherFunctionName` |
| `BucketCleanupFunctionName` | `BucketCleanupFunctionName` |
| `GlueJobName` | `BronzeToSilverJobName` |
| `BronzeBucketName` | `BronzeBucketName` |
| `SilverBucketName` | `SilverBucketName` |
| `GoldBucketName` | `GoldBucketName` |
| `IpeaMonthlyRuleName` | `IpeaMonthlyRuleName` |

Deixe todos esses parametros vazios para manter somente o monitoramento da
aplicacao. Ao informar a Lambda Ipea, todos os nomes sao obrigatorios;
o CloudFormation valida a configuracao antes de criar os recursos.
Nao use o nome da stack ou ARN onde se pede nome fisico.

O output `DataLakeDashboardUrl` abre o segundo painel, que mostra erros e
throttles das cinco Lambdas, duracao da ingestao, resultados das cargas,
quantidade de registros, tamanho diario dos tres buckets e entregas do
agendamento mensal. A consulta Logs Insights exibe os resultados recentes;
selecione um intervalo de pelo menos 35 dias para acompanhar a coleta mensal.
O volume S3 e atualizado diariamente e nao confirma ingestao em tempo real;
Gold vazio e esperado, pois nao existe transformacao Silver para Gold.

A Lambda compartilhada Ipea/Comex emite Embedded Metric Format (EMF) no namespace
`CodeTracker/DataLake`, dimensoes `FunctionName` e `FunctionName/Source`.
Os alarmes existentes usam o total por funcao; o painel separa sucessos
por fonte e a consulta de logs mostra `Source`. `IngestionSuccess=1` e
`RecordsIngested` so sao registrados apos Glue `SUCCEEDED` e verificacao de
Parquet nao vazio no Silver. `IngestionFailure=1` captura tambem falhas
tratadas que retornam `FAILED` ao CloudFormation, sem incrementar o
`AWS/Lambda Errors`. Exclusao do custom resource nao conta como ingestao.
`RecordsIngested` conta registros coletados, nao somente aceitos; as
contagens de qualidade ficam no relatorio de processamento do Silver.
EMF usa os logs da Lambda e nao exige `cloudwatch:PutMetricData`, novas roles
ou ampliacao de IAM; a `LabRole` ainda precisa permitir gravacao de logs.

Os novos alertas do data lake notificam falha logica da ingestao, erros
nativos e throttles nas Lambdas, HTTP 5xx da Function URL de upload,
duracao Ipea superior a 12 minutos e falhas definitivas de entrega do
agendamento. Eventos Glue `FAILED`, `TIMEOUT` e `STOPPED` do job configurado
sao encaminhados diretamente pelo EventBridge ao SNS, incluindo o ID da
execucao. A politica do topico autoriza apenas a regra criada nesta stack,
sem criar roles IAM. O email ainda exige confirmacao da assinatura.
Alertas nao sao retroativos: falhas anteriores a stack de observabilidade
devem ser investigadas nos eventos CloudFormation e logs dos servicos.

Limites importantes: EC2 status check nao verifica o processo MySQL,
RabbitMQ ou a saude das replicas Swarm. Nao ha agente coletando memoria,
disco livre, filas RabbitMQ, logs/journal das VMs ou idade do ultimo dump;
falhas de backup/failover continuam no journal do standby.
Nao existe alarme automatico de atraso mensal ou regra desativada:
confira a ultima carga no painel e o agendamento. Ausencia de metricas
esparsas das Lambdas entre coletas e normal e nao e tratada como falha.
Falhas logicas tratadas do publisher/limpeza devem ser verificadas nos
eventos CloudFormation, pois nao sao erros nativos de execucao Lambda.
Metricas customizadas EMF, alarmes, dashboards e consultas Logs Insights
podem gerar custos adicionais. A stack nao altera a retencao de logs.

Contratos offline dos paineis:
`python -m unittest discover -s "IaC CloudFormation\tests" -p observability_test.py`.

## 5. Encerrar o ambiente

1. Interrompa o teste de carga e faca backup do banco se precisar dos dados.
   Excluir a stack principal tambem exclui os dois volumes MySQL e os dumps.
2. Se criou a stack de observabilidade, exclua-a pelo CloudFormation e
   aguarde `DELETE_COMPLETE`.
3. Antes de excluir, acesse a AZ1 pelo `DatabaseStandbySshCommand` e pare os
   timers com
   `sudo systemctl stop codetracker-database-backup.timer codetracker-database-failover.timer`.
   Aguarde qualquer copia/promocao ja em andamento terminar, para evitar
   disparar failover durante a remocao dos recursos.
   Se houve promocao, com a aplicacao ja fora de uso, devolva o registro A
   `DatabaseEndpoint` ao IP original `DatabasePrivateIp` no Route 53 antes de
   excluir: o valor alterado pelo agente pode causar divergencia na exclusao
   do registro gerenciado pelo CloudFormation.
   Exclua a stack principal pelo CloudFormation e aguarde `DELETE_COMPLETE`.
   Se algum recurso ficar em `DELETE_FAILED`, leia o motivo nos eventos e
   resolva a dependencia antes de repetir a exclusao.
4. Confira se nao restaram recursos cobraveis da implantacao, especialmente
   NAT Gateways, Elastic IPs, EC2, ALB e EBS. Nao remova recursos de outras
   stacks ou ambientes.
5. Os parametros SSM criados pelos scripts em
   `/<EnvironmentName>/swarm/*`, `/<EnvironmentName>/database/ready` e
   `/<EnvironmentName>/database/standby-ready` nao sao
   recursos gerenciados pelo template. Depois de confirmar que nenhuma
   stack usa esse prefixo, remova somente esses parametros no Parameter Store,
   incluindo o token de worker e eventual token de manager residual de versoes
   anteriores, somente se nenhum ambiente ainda utilizar esses parametros.

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
a aplicacao para uso real. O backend e etiquetas recebem a mesma conta SMTP
por `MAIL_USERNAME` e pelo secret `MAIL_PASSWORD`; etiquetas recebe ainda
`ETIQUETA_EMAIL_DESTINATARIO`, o banco MySQL e os brokers RabbitMQ.
O registro `solicitacao_etiqueta` e criado no banco pelo Hibernate (`update`).

A importacao so ocorre em banco sem tabelas. O commit importado fica registrado
em `/var/lib/mysql/.lamar-import-complete`, no EBS. Um banco com tabelas e sem
esse marcador bloqueia o bootstrap para evitar sobrescrever dados ou repetir
inserts; uma importacao parcial exige revisao manual, nao exclusao automatica.
O manager aguarda os parametros SSM `/<EnvironmentName>/database/ready` e
`/<EnvironmentName>/database/standby-ready` contendo o ID da stack atual antes
de subir os containers. O backend recebe DNS privado estavel, nome, usuario
e senha do MySQL, sem precisar de uma nova imagem.
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
sudo docker service ps codetracker_etiquetas --no-trunc
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
Tambem cobrem brokers saudaveis/falhos nos backends, seu ingresso como workers, ausencia de referencias ao
manager AZ2, recusa de stack-id antigo, ausencia de nos e etiquetas incompleto.
Os testes Python de renderizacao usam PyYAML (dependencia do `cfn-lint`) e
validam contagens, Compose, seguranca, memoria e dashboards dos hosts consolidados.

Evite compartilhar logs ou arquivos que contenham credenciais.

No banco AZ1, acessivel pelo output `DatabaseStandbySshCommand`, confira:

Se o WaitCondition informar `initial-database-backup`, consulte primeiro o
log do cloud-init: o backup inicial roda no UserData, antes de instalar os
timers, e nao necessariamente aparece no journal do servico de backup.
O marcador identifica uma etapa, nao a causa raiz. Nesta versao, as etapas
sao separadas: `initial-database-backup` (dump/restauracao/validacao),
`database-recovery-timers` (instalacao dos timers) e `database-standby-ready`
(publicacao SSM). Em versoes anteriores, as tres compartilhavam a primeira marca.

Se o WaitCondition informar `DatabaseStandbyInstance: configuration`, a marca
e generica e nao identifica o comando que falhou. Consulte os logs da tentativa
atual; o erro anterior de `mysqldump` nao pode ser presumido para outra falha.
O bootstrap agora distingue tambem as etapas anteriores ao primeiro backup:

| Etapa | Operacoes |
| --- | --- |
| `database-host-configuration` | Configuracao do hostname |
| `database-mysql-configuration` | Ativacao de MySQL/SSH, arquivos de configuracao, reinicio e validacao do bind |
| `database-accounts` | Criacao/atualizacao do usuario da aplicacao e permissoes |
| `database-recovery-configuration` | Arquivos locais do agente e consulta ao IMDS |
| `database-recovery-agent` | Obtencao do agente via metadados do CloudFormation |
| `database-primary-ready` | Espera pelo marcador SSM de prontidao do primario |

Cada etapa acima registra seu inicio, sem imprimir comandos SQL ou credenciais.
Esses marcadores melhoram o diagnostico; nao corrigem por si a causa da falha.
Uma alteracao local no template nao muda os logs de uma VM ja criada.
Colete as evidencias antes de recriar recursos, e nao reexecute todo o cloud-init.

```bash
sudo tail -n 120 /var/log/cloud-init-output.log
sudo journalctl -u mysql -n 80 --no-pager
sudo journalctl -k --no-pager | grep -Ei 'out of memory|oom|killed process' | tail -n 20
```

Procure o traceback `Operacao de recuperacao falhou` e a ultima mensagem de
erro de `mysqldump`, `mysql`, disco ou AWS CLI. Nao compartilhe `primary.cnf`,
UserData ou credenciais. OOM e uma possibilidade em `t3.micro`, nao uma
conclusao sem logs. Nao amplie privilegios MySQL nem aumente timeouts apenas
com base no nome da etapa. Nao exclua a stack antes de coletar as evidencias.

Se aparecer `mysqldump: [ERROR] unknown variable 'connect-timeout=5'`, a falha
ocorre no processamento das opcoes do cliente, antes de exportar os dados.
O arquivo `/etc/codetracker/primary.cnf` e compartilhado por `mysql` e
`mysqldump`. Ambos leem `[client]`, mas `connect-timeout` e uma opcao do
cliente `mysql` que esse `mysqldump` nao aceita. O template agora deixa
somente host, usuario e senha em `[client]`, e coloca `connect-timeout=5`
em um grupo separado `[mysql]`. Nao e necessario conceder privilegios extras.

Para uma VM ja criada, insira uma linha `[mysql]` imediatamente antes de
`connect-timeout=5` no `primary.cnf`, mantendo host, usuario e senha em
`[client]`. Preserve as permissoes restritivas do arquivo e nao publique seu
conteudo. Nao execute novamente todo o UserData/cloud-init. Corrigir esse
arquivo nao conclui os passos seguintes do bootstrap (timers, SSM e sinais)
nem reverte um WaitCondition ja em `CREATE_FAILED`. Planeje a retomada ou
nova implantacao de acordo com o estado da stack, preservando os dados.
O teste offline de configuracao impede que o timeout volte ao grupo `[client]`.

```bash
sudo systemctl list-timers 'codetracker-database-*'
sudo journalctl -u codetracker-database-backup.service -n 100 --no-pager
sudo journalctl -u codetracker-database-failover.service -n 100 --no-pager
sudo ls -lh /var/lib/mysql/.codetracker-recovery/
sudo cat /var/lib/mysql/.codetracker-recovery/last-backup
sudo mysql -e 'SELECT @@global.read_only, @@global.super_read_only;'
```

`last-backup` contem o horario Unix do inicio da ultima copia bem-sucedida.
Antes do failover, as duas variaveis de somente leitura devem ser `1`;
depois, `0`. O arquivo `promoted` indica promocao concluida; se existir apenas
`promotion-prepared`, consulte os logs de DNS/IAM. Nao apague esses marcadores:
eles impedem restaurar um dump antigo por cima de escritas novas.

Para um teste de failover em ambiente descartavel, confirme o primeiro dump
e pare a EC2 `DatabaseInstance` (AZ2) pelo console. Observe a promocao nos
logs da AZ1 e teste consulta e escrita pelo frontend apos a troca.
Nao reinicie o antigo principal nem use esse teste com dados a preservar.
Para o RabbitMQ local de cada backend, use `RabbitMqManagementTunnelCommand` (porta local 15672)
ou `RabbitMqAz2ManagementTunnelCommand` (porta local 15673). Os paineis
mostram brokers e filas separados, nao replicas.

Testes offline do agente, sem acessar AWS nem MySQL:

```powershell
python -m unittest discover -s ".\IaC_Grupo7\IaC CloudFormation\tests" -p database_recovery_test.py
```

## Limites

- A automacao foi feita para criacao de uma stack nova. Mudar UserData ou a tag
  em uma stack existente nao garante reexecutar cloud-init nem atualizar os
  servicos automaticamente. Nao reutilize a WaitConditionHandle de uma criacao
  anterior em uma atualizacao; use uma stack nova para esta versao do bootstrap.
- O manager unico AZ1 fica em `Drain`: perde-lo impede novos agendamentos
  e mudancas. Nao ha standby tolerante a falhas. O verificador/deploy automatico
  permanece na AZ1. Para tolerar uma falha de manager, use tres.
- A recuperacao do MySQL e unilateral (AZ2 para AZ1), com perda de dados e interrupcao, nao
  replicacao continua nem RDS Multi-AZ. A perda da AZ1 remove o standby.
- Os dois RabbitMQ sao independentes; nao ha sincronizacao de mensagens,
  quorum ou garantia de continuidade dos consumidores.
  Cada host compartilha recursos e dominio de falha com dois backends e uma replica etiquetas.
  O volume Docker `rabbitmq-data` e local, nao e backup externo nem armazenamento
  compartilhado; preserve mensagens e definicoes antes de substituir a EC2.
- O ALB usa HTTP. Configure HTTPS e cookies seguros antes de uso em producao.
- O SSH publico do bastion continua aberto no template; restrinja ao seu IP.
- Ha custos com oito EC2 (quatro `t3.micro`, duas `t3.small` e duas `t3.medium`),
  dois NAT Gateways, ALB,
  dois volumes de dados EBS, zona DNS privada, consultas DNS e IPs publicos.
- Excluir a stack tambem exclui os volumes e dumps do banco: faca backup antes.

O arquivo `../docker-compose.yml` continua sendo o ambiente local; a stack
Swarm da AWS e gerada em `/opt/codetracker/stack.yml` no manager.