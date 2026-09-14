# Data Lake Lamar Autopecas - Terraform

Stack Terraform independente para criar as camadas Bronze, Silver e Gold no Amazon S3. O AWS Glue sera acrescentado posteriormente. Esta stack nao precisa de Docker.

## Arquivos

- `main.tf`: versoes do Terraform/provider, provider AWS e tags comuns.
- `variables.tf`: variaveis e validacoes.
- `terraform.tfvars.example`: modelo dos valores locais.
- `storage.tf`: buckets, versionamento, criptografia, bloqueio publico e ownership.
- `outputs.tf`: nomes e ARNs dos buckets.

O antigo output `application_url` foi removido porque esta stack nao possui ALB nem aplicacao.

## 1. Preparar as variaveis

No PowerShell:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

No Linux, macOS ou Git Bash:

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edite `terraform.tfvars` e troque `grupo01` por um identificador curto do integrante ou do grupo. Nao coloque chaves AWS nesse arquivo.

O atributo `bucket_prefix` faz o provider acrescentar um sufixo unico. Um nome final podera se parecer com:

```text
lamar-pecas-grupo01-dev-bronze-20260913123456789000000001
```

## 2. Configurar credenciais temporarias

Em ambientes como AWS Academy Learner Lab, inicie o laboratorio e copie as credenciais temporarias exibidas na area de detalhes/credenciais AWS. Elas normalmente possuem tres valores: access key, secret access key e session token.

PowerShell:

```powershell
$env:AWS_ACCESS_KEY_ID="COLE_A_ACCESS_KEY"
$env:AWS_SECRET_ACCESS_KEY="COLE_A_SECRET_KEY"
$env:AWS_SESSION_TOKEN="COLE_O_SESSION_TOKEN"
$env:AWS_DEFAULT_REGION="us-east-1"
```

Linux, macOS ou Git Bash:

```bash
export AWS_ACCESS_KEY_ID="COLE_A_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="COLE_A_SECRET_KEY"
export AWS_SESSION_TOKEN="COLE_O_SESSION_TOKEN"
export AWS_DEFAULT_REGION="us-east-1"
```

Esses valores expiram. Quando o laboratorio reiniciar ou a sessao vencer, copie um novo conjunto. Nunca salve credenciais em arquivos `.tf`, `terraform.tfvars`, Git ou mensagens.

Confirme a identidade antes de criar recursos:

```bash
aws sts get-caller-identity
```

## 3. Validar e criar os buckets

Execute dentro desta pasta:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Confira os nomes criados:

```bash
terraform output
aws s3 ls
```

## 4. Testar a camada Bronze

Crie localmente um pequeno arquivo `amostra.csv` e envie-o ao prefixo `incoming/`.

PowerShell:

```powershell
$bucket = terraform output -raw bronze_bucket_name
aws s3 cp amostra.csv "s3://$bucket/incoming/amostra.csv"
aws s3 ls "s3://$bucket/incoming/"
```

Linux, macOS ou Git Bash:

```bash
bucket_name=$(terraform output -raw bronze_bucket_name)
aws s3 cp amostra.csv "s3://${bucket_name}/incoming/amostra.csv"
aws s3 ls "s3://${bucket_name}/incoming/"
```

## 5. Remover os recursos do laboratorio

Com os buckets vazios:

```bash
terraform destroy
```

Por seguranca, `force_destroy_buckets` e `false`. Se houver objetos ou versoes armazenados, o S3 impedira a exclusao do bucket. Em um ambiente exclusivamente descartavel, voce pode definir `force_destroy_buckets = true`, aplicar a alteracao e depois executar `terraform destroy`.

## Restricoes possiveis da conta estudantil

Alguns laboratorios limitam regioes, servicos ou permissoes. Se `aws sts get-caller-identity` funcionar, mas o `terraform apply` retornar `AccessDenied`, a configuracao pode estar correta e a role estudantil pode nao permitir alguma operacao. Guarde a mensagem completa para identificar exatamente a permissao bloqueada.

## Proxima etapa: AWS Glue

Quando o ETL entrar no escopo, os outputs `data_lake_bucket_arns` poderao alimentar:

- uma role do Glue com acesso minimo aos buckets;
- Glue Database e Glue Data Catalog;
- Crawlers;
- Jobs de ETL Bronze para Silver e Silver para Gold.

Ao adicionar Glue, mantenha esta mesma stack e o mesmo arquivo de estado, ou mova os recursos de estado de forma controlada. Nao copie os buckets para outra stack sem importar ou mover o estado, pois duas stacks nao devem gerenciar o mesmo recurso.
