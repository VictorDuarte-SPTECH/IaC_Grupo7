# Terraform principal fragmentado

Esta pasta contém a mesma stack principal organizada por responsabilidade:

- `main.tf`: configuração do Terraform, provider AWS e fontes de dados;
- `variables.tf`: variáveis de entrada;
- `network.tf`: VPC, sub-redes, gateways, rotas e Security Groups;
- `instances.tf`: EC2, EBS, Application Load Balancer e scripts `user_data`;
- `observability.tf`: CloudWatch e SNS;
- `storage.tf`: buckets antigos do Data Lake, mantidos temporariamente;
- `outputs.tf`: valores exibidos após o provisionamento.

Todos os arquivos `.tf` desta pasta formam uma única configuração e uma única
stack. A separação não cria módulos nem estados diferentes.

## Docker

O `user_data` das cinco instâncias EC2 agora instala o pacote `docker.io`,
habilita o serviço Docker e adiciona o usuário `ubuntu` ao grupo `docker`.
Nenhuma imagem é baixada e nenhum container é iniciado nesta etapa.

## Atenções antes do primeiro apply

1. O Data Lake já foi criado por outra stack. Desative `storage.tf` e remova os
   três outputs correspondentes de `outputs.tf` antes de aplicar esta stack.
2. Apache e Nginx continuam sendo instalados juntos. Essa configuração foi
   preservada para a etapa posterior de limpeza do `user_data` e pode causar
   conflito na porta 80.
3. O agente do CloudWatch precisa de permissões IAM para publicar métricas. A
   conta acadêmica disponibiliza apenas a `LabRole`; não são criadas novas roles
   por esta configuração.
4. A `LabRole` é uma role, mas a EC2 recebe um *instance profile*. É necessário
   confirmar o nome do instance profile disponível na conta antes de associá-lo
   à instância do banco.
5. O volume EBS ainda é apenas anexado à EC2. Ele não é formatado, montado nem
   configurado como destino do MySQL nesta versão.

## Comandos iniciais

Copie o exemplo de variáveis para `terraform.tfvars`, ajuste os valores e rode:

```powershell
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
```

Analise o plano antes de executar qualquer `apply`.
