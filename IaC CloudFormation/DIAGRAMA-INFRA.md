# Infraestrutura Lamar Auto Pecas

```mermaid
flowchart TB
    Internet([Internet])
    Admin([Administrador])
    Cliente([Cliente HTTP])

    subgraph AWS["AWS - VPC 10.0.0.0/25"]
        ALB[Application Load Balancer]
        SSM[(SSM Parameter Store<br/>token worker criptografado)]

        subgraph AZ1[Zona de disponibilidade 1]
            subgraph Publica1[Subnet publica AZ1 - 10.0.0.0/27]
                Bastion[Bastion SSH + Elastic IP]
                Nat1[NAT Gateway AZ1]
            end

            subgraph Web1Subnet[Subnet web AZ1 - 10.0.0.64/28]
                Web1[web-az1<br/>Swarm worker]
            end

            subgraph Backend1Subnet[Subnet backend AZ1 - 10.0.0.96/28]
                Manager[swarm-manager-az1<br/>manager em drain]
                Backend1[backend-az1<br/>Swarm worker]
            end
        end

        subgraph AZ2[Zona de disponibilidade 2]
            subgraph Publica2[Subnet publica AZ2 - 10.0.0.32/27]
                Nat2[NAT Gateway AZ2]
            end

            subgraph Web2Subnet[Subnet web AZ2 - 10.0.0.80/28]
                Web2[web-az2<br/>Swarm worker]
            end

            subgraph Backend2Subnet[Subnet backend AZ2 - 10.0.0.112/28]
                Backend2[backend-az2<br/>Swarm worker]
                Database[(VM MySQL AZ2)]
                EBS[(Volume EBS)]
            end
        end
    end

    Cliente -->|HTTP 80| Internet
    Internet --> ALB
    ALB -->|HTTP 80| Web1
    ALB -->|HTTP 80| Web2

    Web1 -->|TCP 8080| Backend1
    Web1 -->|TCP 8080| Backend2
    Web2 -->|TCP 8080| Backend1
    Web2 -->|TCP 8080| Backend2
    Backend1 -->|MySQL 3306| Database
    Backend2 -->|MySQL 3306| Database
    Database --- EBS

    Admin -->|SSH/SFTP 22, qualquer IPv4| Bastion
    Bastion -->|SSH/SFTP 22| Manager
    Bastion -.->|SSH 22| Web1
    Bastion -.->|SSH 22| Web2
    Bastion -.->|SSH 22| Backend1
    Bastion -.->|SSH 22| Backend2
    Bastion -.->|SSH 22| Database

    Manager -->|Publica token SecureString| SSM
    SSM -->|Workers leem o token| Web1
    SSM -->|Workers leem o token| Web2
    SSM -->|Workers leem o token| Backend1
    SSM -->|Workers leem o token| Backend2

    Manager <-.->|Swarm 2377, 7946 e 4789| Web1
    Manager <-.->|Swarm 2377, 7946 e 4789| Web2
    Manager <-.->|Swarm 2377, 7946 e 4789| Backend1
    Manager <-.->|Swarm 2377, 7946 e 4789| Backend2

    Web1 -.->|Saida| Nat1
    Backend1 -.->|Saida| Nat1
    Manager -.->|Saida| Nat1
    Web2 -.->|Saida| Nat2
    Backend2 -.->|Saida| Nat2
    Database -.->|Saida| Nat2
    Nat1 --> Internet
    Nat2 --> Internet
```

## Bootstrap automatico do Swarm

Durante a primeira inicializacao:

1. O manager instala Docker e AWS CLI, define o hostname `swarm-manager-az1` e executa `docker swarm init`.
2. O token de worker e salvo como `SecureString` em `/<EnvironmentName>/swarm/worker-token` no SSM Parameter Store.
3. As VMs web e backend aguardam o parametro e executam `docker swarm join` automaticamente.
4. O manager aplica as labels `tier=web|backend` e `zone=az1|az2` aos workers.
5. O manager permanece em `drain`, portanto nao executa os containers da aplicacao.

O IAM role contido em `InstanceProfileName` precisa permitir:

- `ssm:PutParameter` para o manager;
- `ssm:GetParameter` para os workers;
- `kms:Encrypt`, `kms:Decrypt` e `kms:GenerateDataKey` para o `SecureString`.

No ambiente AWS Academy, confirme essas permissoes no role associado ao `LabInstanceProfile`.

## Acesso SSH e SFTP

Ao criar a stack, informe:

- `KeyName`: nome de um par de chaves EC2 existente na regiao.

O bastion aceita conexoes SSH na porta 22 a partir de qualquer endereco IPv4 (`0.0.0.0/0`). A autenticacao continua exigindo a chave privada correspondente ao `KeyName`.

Use os outputs `BastionPublicIp` e `SwarmManagerPrivateIp`:

```sshconfig
Host lamar-bastion
    HostName IP_PUBLICO_BASTION
    User ubuntu
    IdentityFile C:/Users/Guilherme/.ssh/lamar.pem

Host lamar-manager
    HostName IP_PRIVADO_MANAGER
    User ubuntu
    IdentityFile C:/Users/Guilherme/.ssh/lamar.pem
    ProxyJump lamar-bastion
```

Envie e implante o arquivo da stack:

```bash
sftp lamar-manager
```

```text
put docker-swarm.yml /home/ubuntu/docker-swarm.yml
exit
```

```bash
ssh lamar-manager
sudo docker node ls
sudo docker stack deploy --with-registry-auth -c /home/ubuntu/docker-swarm.yml lamar
```

Este desenho usa um unico manager e e adequado para laboratorio. Alta disponibilidade exige tres managers, preferencialmente distribuidos em tres zonas de disponibilidade.
