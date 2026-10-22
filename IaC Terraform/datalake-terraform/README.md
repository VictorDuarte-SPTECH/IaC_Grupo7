# Encerramento do state legado

O provisionamento do Data Lake foi removido. Esta pasta mantém somente o
provider AWS para permitir encerrar recursos registrados em um state Terraform
existente.

Se houver um state legado nesta pasta, revise o plano de exclusao antes de
executar:

```powershell
terraform init
terraform plan -destroy
terraform destroy
```

Recursos S3 com objetos ou versoes precisam ser esvaziados antes da exclusao.
Se nao houver state local ou remoto configurado, estes comandos nao localizarao
os recursos antigos.
