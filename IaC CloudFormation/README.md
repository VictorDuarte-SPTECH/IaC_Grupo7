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
   chave JWT Base64. O exemplo de geracao da chave no passo 2 requer Python 3.
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
  32 bytes (256 bits), nao uma senha de usuario. Gere uma nova com
  `python3 -c "import base64, secrets; print(base64.b64encode(secrets.token_bytes(32)).decode())"`.
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