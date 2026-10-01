# Terraform principal fragmentado

Esta pasta contém a mesma stack principal organizada por responsabilidade:

- `main.tf`: configuração do Terraform, provider AWS e fontes de dados;
- `variables.tf`: variáveis de entrada;
- `network.tf`: VPC, sub-redes, gateways, rotas e Security Groups;
- `instances.tf`: EC2, Docker Swarm, RabbitMQ, EBS, MySQL, Application Load Balancer e scripts `user_data`;
- `storage.tf.disabled`: buckets antigos do Data Lake, preservados e ignorados;
- `outputs.tf`: valores exibidos após o provisionamento.

Todos os arquivos `.tf` desta pasta formam uma única configuração e uma única
stack. A separação não cria módulos nem estados diferentes.

## Docker Swarm

O manager inicializa o cluster, publica o token de worker no Parameter Store e
aplica labels de camada e zona aos quatro workers. As duas VMs web e as duas VMs
backend consultam o token e entram automaticamente no cluster.

O manager fica em modo `drain`, portanto as aplicações devem ser implantadas nos
workers usando as labels `tier=web`, `tier=backend`, `zone=az1` e `zone=az2`.
O instance profile precisa permitir leitura e escrita do parâmetro
`/<environment_name>/swarm/worker-token` no SSM Parameter Store.

Alterações futuras no `user_data` substituem a respectiva EC2 para garantir que
o novo script seja realmente executado.

## RabbitMQ e banco de dados

Uma VM dedicada executa `rabbitmq:4-management-alpine`, com AMQP na porta 5672.
A interface de administração na porta 15672 não é aberta na rede; o output
`rabbitmq_management_tunnel_command` fornece o túnel SSH pelo bastion.

Na primeira inicialização da instância do banco, o `user_data`:

1. aguarda o EBS ser anexado;
2. formata o volume como `ext4` somente se ele ainda estiver vazio;
3. monta o volume em `/var/lib/mysql` e registra seu UUID no `/etc/fstab`;
4. instala e inicia o MySQL sobre esse volume;
5. habilita conexões na interface privada;
6. cria o banco e o usuário definidos nas variáveis.

Esta stack não cria recursos de observabilidade, seguindo o template
CloudFormation usado como referência.

## LabRole e instance profile

A conta acadêmica fornece a `LabRole`, mas uma EC2 recebe um IAM instance
profile, não o nome da role diretamente. Confirme o profile associado com:

```bash
aws iam list-instance-profiles-for-role \
  --role-name LabRole \
  --query "InstanceProfiles[].InstanceProfileName" \
  --output text
```

O valor normalmente utilizado no Learner Lab é `LabInstanceProfile`, mas o
resultado do comando é a fonte correta para a conta atual. Coloque o nome em
`instance_profile_name` no `terraform.tfvars`.

O profile é associado ao manager, aos quatro workers e ao banco. O bastion e o
RabbitMQ não usam instance profile, assim como no CloudFormation de referência.

## Acesso administrativo

O bastion recebe um Elastic IP e é o único ponto de entrada SSH público. As VMs
privadas aceitam SSH/SFTP apenas a partir do security group do bastion. Informe
em `key_name` um par de chaves EC2 existente na região.

## Atenções antes do primeiro apply

1. Confirme o `instance_profile_name` antes do `plan`.
2. Defina `key_name`, `rabbitmq_password` e `database_password` no
   `terraform.tfvars`.
3. O Data Lake está desativado nesta stack; não renomeie `storage.tf.disabled`
   para `.tf`.
4. A aplicação web não é iniciada por esta stack. Portanto, os targets do ALB ficarão
   sem aplicações saudáveis até a etapa dos containers.
5. Dois NAT Gateways e um Application Load Balancer consomem orçamento enquanto
   permanecerem provisionados.
6. As senhas são marcadas como sensíveis na interface do Terraform, mas ficam
   armazenadas no state. Proteja o arquivo ou backend de estado.

## Comandos iniciais

Copie o exemplo de variáveis para `terraform.tfvars`, ajuste os valores e rode:

```powershell
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
```

Analise o plano antes de executar qualquer `apply`.

Se já existir um `tfplan` anterior, remova-o e gere outro, pois planos salvos
não incorporam alterações posteriores nos arquivos `.tf`.
