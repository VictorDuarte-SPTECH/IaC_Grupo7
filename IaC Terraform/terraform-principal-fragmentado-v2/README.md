# Terraform principal fragmentado

Esta pasta contém a mesma stack principal organizada por responsabilidade:

- `main.tf`: configuração do Terraform, provider AWS e fontes de dados;
- `variables.tf`: variáveis de entrada;
- `network.tf`: VPC, sub-redes, gateways, rotas e Security Groups;
- `instances.tf`: EC2, EBS, Application Load Balancer e scripts `user_data`;
- `observability.tf`: CloudWatch e SNS;
- `storage.tf.disabled`: buckets antigos do Data Lake, preservados e ignorados;
- `outputs.tf`: valores exibidos após o provisionamento.

Todos os arquivos `.tf` desta pasta formam uma única configuração e uma única
stack. A separação não cria módulos nem estados diferentes.

## Docker

O `user_data` das cinco instâncias EC2 agora instala o pacote `docker.io`,
habilita o serviço Docker e adiciona o usuário `ubuntu` ao grupo `docker`.
Nenhuma imagem é baixada e nenhum container é iniciado nesta etapa.

Apache, Nginx, Node.js e `create-react-app` foram removidos das máquinas porque
as aplicações serão executadas posteriormente em containers. A instância do
banco mantém o MySQL instalado diretamente no Ubuntu.

Alterações futuras no `user_data` substituem a respectiva EC2 para garantir que
o novo script seja realmente executado.

## Banco, EBS e observabilidade

Na primeira inicialização da instância do banco, o `user_data`:

1. aguarda o EBS ser anexado;
2. formata o volume como `ext4` somente se ele ainda estiver vazio;
3. monta o volume em `/var/lib/mysql` e registra seu UUID no `/etc/fstab`;
4. instala e inicia o MySQL sobre esse volume;
5. instala o pacote oficial do CloudWatch Agent;
6. publica `disk_used_percent` no namespace `CWAgent`;
7. permite que o alarme envie uma notificação quando o uso alcançar 70%.

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

O mesmo profile é associado às cinco EC2, permitindo o uso futuro do Systems
Manager para diagnóstico, caso esse serviço esteja autorizado no laboratório.

## Alertas por e-mail

`alert_email` começa vazio. Nesse caso, o tópico e o alarme são criados, mas a
assinatura de e-mail não é criada. Para receber alertas, informe um endereço
real no `terraform.tfvars` e confirme a mensagem enviada pelo SNS.

## Atenções antes do primeiro apply

1. Confirme o `instance_profile_name` antes do `plan`.
2. O Data Lake está desativado nesta stack; não renomeie `storage.tf.disabled`
   para `.tf`.
3. Nenhum container é iniciado ainda. Portanto, os target groups do ALB ficarão
   sem aplicações saudáveis até a etapa dos containers.
4. Dois NAT Gateways e um Application Load Balancer consomem orçamento enquanto
   permanecerem provisionados.

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
