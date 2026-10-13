# Deploy da aplicacao com CloudFormation e Docker Swarm

O template `cloudformationCodeTracker.yaml` instala Docker nas VMs da
aplicacao, MySQL na VM de banco e RabbitMQ em uma VM dedicada. O manager
descobre os quatro workers, aplica labels e executa `docker stack deploy`.

## 1. Publicar as imagens corrigidas

Na raiz do projeto, com Docker em execucao, use o terminal Bash:

```bash
bash IaC_Grupo7/publicar-dockerhub.sh guilhermebarros297 v1.0.1
```

Os tres repositorios no Docker Hub precisam ser publicos. A imagem anterior
do frontend usa `localhost:8080`; a nova usa `/api` em producao. Nao reutilize
uma tag antiga para a versao corrigida. A arquitetura esperada e Linux amd64.

## 2. Criar uma stack nova

No console AWS CloudFormation, envie `cloudformationCodeTracker.yaml` e informe:

- `DockerHubNamespace`: `guilhermebarros297`.
- `ApplicationImageTag`: `v1.0.1`, depois de publicar as tres imagens.
- `KeyName`: um par de chaves EC2 existente na regiao.
- `InstanceProfileName`: um perfil IAM existente, por exemplo `LabInstanceProfile`.
- `DatabasePassword` e `RabbitMqPassword`: senhas distintas com pelo menos 12 caracteres.
- `JwtSecret`: chave aleatoria com pelo menos 32 caracteres, nao uma senha de usuario.
- `InstanceType`: `t3.small` por padrao, com memoria para os containers Java.

Use uma regiao com ao menos duas zonas de disponibilidade e acesso ao parametro
SSM da AMI Ubuntu. O perfil das VMs precisa permitir `ssm:PutParameter` e
`ssm:GetParameter` em `/<EnvironmentName>/swarm/*`, `kms:Decrypt` para ler o
SecureString com a chave usada pelo SSM e `cloudformation:SignalResource` na
stack. Tambem sao necessarias `ssm:PutParameter` e `ssm:GetParameter` em
`/<EnvironmentName>/database/ready`. O usuario que cria a stack tambem precisa
poder associar esse perfil.

O manager publica `/<EnvironmentName>/swarm/stack-id` somente depois do IP e
do token. Os workers so usam esses parametros quando o marcador corresponde
ao ID da stack atual, evitando entrada em um cluster de uma implantacao antiga.
Nao execute stacks simultaneas com o mesmo `EnvironmentName` na mesma regiao.
Os sete bootstraps usam a mesma rotina definida em `Mappings.Bootstrap`:

- Atualizacao completa dos indices APT por IPv4, com timeout de ate 60 segundos
  por tentativa e janela total de 600 segundos. Tentativas ficam separadas por
  ate 10 segundos; a ultima tentativa usa apenas o tempo restante. A terminacao
  forcada de um processo pode acrescentar ate 5 segundos ao limite.
- Cada tentativa registra horario UTC, instancia, prazo restante, erro do APT
  e codigo de retorno em `/var/log/cloud-init-output.log`. Nenhum pacote e
  instalado se algum indice continuar indisponivel.
- Instalacao dos pacotes limitada a 600 segundos, com retries de download e
  espera limitada pelo lock do dpkg. Uma falha interrompe a configuracao; nao
  ha reexecucao automatica de todo o script nem descarte de estado do Swarm.
- Download da AWS CLI com timeout e retries limitados. A extracao sobrescreve
  arquivos temporarios sem perguntas interativas.
- Ao terminar, cada VM envia SUCCESS ou FAILURE ao `BootstrapWaitCondition`
  por uma URL S3 pre-assinada, sem depender da instalacao da AWS CLI ou de
  permissoes IAM adicionais para esse sinal. A URL e sensivel: nao a publique.

O `BootstrapWaitCondition` exige sete sinais unicos em ate 3600 segundos.
Uma falha identifica o recurso logico e a etapa, por exemplo
`WebInstanceAz1: apt-update-exhausted`; o motivo detalhado do APT fica no log.
Isso inclui banco e RabbitMQ, que antes nao confirmavam seu bootstrap.
O bastion nao faz parte dessa contagem porque nao tem bootstrap personalizado.
O sucesso do bootstrap do manager nao substitui o teste da aplicacao.

O sinal pre-assinado precisa de acesso HTTPS ao endpoint S3 da URL, inclusive
em VPCs que usam endpoints com politicas restritivas. Para falhas antes de
instalar pacotes, a sinalizacao usa o curl ja presente na AMI Ubuntu selecionada.
Se a VM nao tiver curl, ou a rede impedir o acesso ao S3, nao ha como garantir
notificacao imediata: o log registra a impossibilidade e a stack falha pelo
timeout. A janela APT tolera uma indisponibilidade transitoria, mas nao corrige
rotas, NAT, ACLs ou security groups configurados incorretamente.

O manager tem ate 60 minutos para sinalizar prontidao, acomodando a recuperacao
de rede e a instalacao. Os prazos da WaitCondition e do manager comecam quando
seus respectivos recursos iniciam a criacao; nao sao reiniciados por comandos
manuais. O manager verifica as replicas,
o frontend e as respostas HTTP dos proxies do backend e de etiquetas. Respostas
4xx nas rotas raiz sao aceitas porque essas rotas podem nao existir ou exigir
autenticacao; isso nao substitui um teste funcional de login ou de pedidos.

## 3. Acessar a aplicacao

Depois de `CREATE_COMPLETE`, abra o output `ApplicationUrl`:

```text
Navegador -> ALB :80 -> frontend/Nginx nas VMs web
                     -> /api/ -> backend :8080 na rede overlay
                     -> /etiquetas-api/ -> etiquetas :8081 na rede overlay
Backend -> MySQL :3306 na VM dedicada
Etiquetas -> backend :8080 na rede overlay
```

Ha duas replicas de frontend, uma por VM web, duas de backend, uma por VM
backend, e uma de etiquetas em uma VM backend. O manager fica em modo drain.
Somente a porta do frontend e publicada; backend e etiquetas sao internos.
O acesso MySQL fica restrito ao security group dos backends. O RabbitMQ esta
disponivel para eles, mas o codigo atual do backend nao possui integracao AMQP.

## Dados e credenciais

A VM de banco clona `https://github.com/EnzoServilha/Banco_Grupo7.git` em
`/opt/Banco_Grupo7` e importa `SCRIPT-Lamar-AutoPecas.sql`. O script fixa o banco
`lamar`, por isso `DatabaseName` aceita apenas esse nome. Sao importadas tabelas,
permissoes e dados de demonstracao, incluindo `admin@teste.com`. A senha desse
administrador esta em hash no SQL: obtenha a senha original com o responsavel
pelo repositorio ou redefina-a de forma segura. Nao e a senha `DatabasePassword`.
Revise/remova os dados de demonstracao e troque as credenciais antes de expor
a aplicacao para uso real. SMTP nao e configurado neste deploy.

A importacao so ocorre em banco sem tabelas. O commit importado fica registrado
em `/var/lib/mysql/.lamar-import-complete`, no EBS. Um banco com tabelas e sem
esse marcador bloqueia o bootstrap para evitar sobrescrever dados ou repetir
inserts; uma importacao parcial exige revisao manual, nao exclusao automatica.
O manager aguarda o parametro SSM `/<EnvironmentName>/database/ready` contendo
o ID da stack atual antes de subir os containers. O backend ja recebe IP,
nome, usuario e senha desse MySQL, sem precisar de uma nova imagem.

Clonar o repositorio importa o SQL versionado, nao copia dados de outro servidor
MySQL. Alteracoes futuras no GitHub nao sao aplicadas automaticamente ao banco;
use migracoes para atualizar um banco existente. A clonagem usa a branch padrao
do repositorio no momento da criacao; para producao, fixe um commit revisado.

As senhas e a chave JWT chegam aos containers por Docker secrets, importados
pelo Spring via `configtree:/run/secrets/`. `NoEcho` mascara parametros no console,
mas nao protege valores presentes no UserData das VMs. Restrinja acesso a EC2,
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
- Ha custos com oito EC2, dois NAT Gateways, ALB, EBS e IPs publicos.
- Excluir a stack tambem exclui o volume do banco: faca backup antes.

O arquivo `../docker-compose.yml` continua sendo o ambiente local; a stack
Swarm da AWS e gerada em `/opt/codetracker/stack.yml` no manager.