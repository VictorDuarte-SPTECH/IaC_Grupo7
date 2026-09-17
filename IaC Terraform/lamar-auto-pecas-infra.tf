# ==============================================================================
# --- CONFIGURAÇÃO DO TERRAFORM E DO PROVIDER AWS ---
# ==============================================================================
# Define o provider utilizado.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Define a região padrão em que os recursos serão provisionados.
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Configura o provider AWS com a região recebida pela variável.
provider "aws" {
  region = var.aws_region
}

# ==============================================================================
# --- VARIÁVEIS GERAIS DO AMBIENTE ---
# ==============================================================================
# Centraliza os valores utilizados em nomes de recursos e tipos de instância.

variable "environment_name" {
  type    = string
  default = "lamar-auto-pecas"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

# ==============================================================================
# --- FONTES DE DADOS DA AWS ---
# ==============================================================================
# Consulta as zonas de disponibilidade ativas e a AMI atual do Ubuntu 24.04.

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

# ==============================================================================
# --- REDE PRINCIPAL: VPC E INTERNET GATEWAY ---
# ==============================================================================
# Cria a VPC do projeto e o gateway responsável pela conexão com a internet.

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/25"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# ==============================================================================
# --- SUB-REDES PÚBLICAS, DE FRONTEND E DE BACKEND ---
# ==============================================================================
# Distribui as sub-redes entre as duas primeiras zonas de disponibilidade.
# As sub-redes públicas recebem IP público automaticamente.
# Frontend e backend permanecem em sub-redes privadas.

resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = "10.0.0.0/27"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[1]
  cidr_block              = "10.0.0.32/27"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "web_az1" {
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[0]
  cidr_block        = "10.0.0.64/28"
}

resource "aws_subnet" "web_az2" {
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[1]
  cidr_block        = "10.0.0.80/28"
}

resource "aws_subnet" "backend_az1" {
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[0]
  cidr_block        = "10.0.0.96/28"
}

resource "aws_subnet" "backend_az2" {
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.available.names[1]
  cidr_block        = "10.0.0.112/28"
}

# ==============================================================================
# --- TABELA DE ROTAS PÚBLICA ---
# ==============================================================================
# Direciona o tráfego externo das sub-redes públicas para o Internet Gateway.

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public_az1" {
  subnet_id      = aws_subnet.public_az1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_az2" {
  subnet_id      = aws_subnet.public_az2.id
  route_table_id = aws_route_table.public.id
}

# ==============================================================================
# --- ELASTIC IPS E NAT GATEWAYS ---
# ==============================================================================
# Cria um endereço público e um NAT Gateway para cada zona de disponibilidade.
# Os NAT Gateways permitem saída para a internet a partir das redes privadas.

resource "aws_eip" "nat_az1" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat_az2" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "az1" {
  allocation_id = aws_eip.nat_az1.id
  subnet_id     = aws_subnet.public_az1.id
}

resource "aws_nat_gateway" "az2" {
  allocation_id = aws_eip.nat_az2.id
  subnet_id     = aws_subnet.public_az2.id
}

# ==============================================================================
# --- TABELAS DE ROTAS PRIVADAS ---
# ==============================================================================
# Cada zona utiliza seu próprio NAT Gateway como rota padrão de saída.
# As redes de frontend e backend da mesma zona compartilham a tabela privada.

resource "aws_route_table" "private_az1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.az1.id
  }
}

resource "aws_route_table" "private_az2" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.az2.id
  }
}

resource "aws_route_table_association" "web_az1" {
  subnet_id      = aws_subnet.web_az1.id
  route_table_id = aws_route_table.private_az1.id
}

resource "aws_route_table_association" "backend_az1" {
  subnet_id      = aws_subnet.backend_az1.id
  route_table_id = aws_route_table.private_az1.id
}

resource "aws_route_table_association" "web_az2" {
  subnet_id      = aws_subnet.web_az2.id
  route_table_id = aws_route_table.private_az2.id
}

resource "aws_route_table_association" "backend_az2" {
  subnet_id      = aws_subnet.backend_az2.id
  route_table_id = aws_route_table.private_az2.id
}

# ==============================================================================
# --- SECURITY GROUP DO APPLICATION LOAD BALANCER ---
# ==============================================================================
# Permite a entrada HTTP pela internet e libera o tráfego de saída do ALB.

resource "aws_security_group" "load_balancer" {
  name_prefix = "${var.environment_name}-alb-"
  description = "Permite HTTP da internet ao ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# --- SECURITY GROUP DO FRONTEND ---
# ==============================================================================
# Aceita HTTP somente a partir do Security Group do Load Balancer.

resource "aws_security_group" "web" {
  name_prefix = "${var.environment_name}-web-"
  description = "Permite HTTP do ALB aos frontends"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# --- SECURITY GROUP DO BACKEND ---
# ==============================================================================
# Aceita conexões na porta 8080 originadas pelo Security Group do frontend.

resource "aws_security_group" "backend" {
  name_prefix = "${var.environment_name}-backend-"
  description = "Permite acesso dos frontends aos backends"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# --- SECURITY GROUP DO BANCO DE DADOS ---
# ==============================================================================
# Aceita conexões MySQL na porta 3306 somente a partir dos backends.

resource "aws_security_group" "database" {
  name_prefix = "${var.environment_name}-database-"
  description = "Permite MySQL somente a partir dos backends"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ==============================================================================
# --- INSTÂNCIAS EC2 DO BACKEND ---
# ==============================================================================
# Cria um backend em cada zona de disponibilidade.
# O user_data instala Apache e Nginx. (A SER ALTERADO)

resource "aws_instance" "backend_az1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.backend_az1.id
  vpc_security_group_ids = [aws_security_group.backend.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    echo "<html><body><h1>Backend AZ1 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Backend AZ1 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

resource "aws_instance" "backend_az2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.backend_az2.id
  vpc_security_group_ids = [aws_security_group.backend.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    echo "<html><body><h1>Backend AZ2 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Backend AZ2 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

# ==============================================================================
# --- INSTÂNCIA EC2 DO BANCO DE DADOS ---
# ==============================================================================
# Cria a instância do banco na segunda zona e executa o script de inicialização.
# O user_data instala Apache, Nginx, MySQL e o agente do CloudWatch. (A SER ALTERADO)

resource "aws_instance" "database_az2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.backend_az2.id
  vpc_security_group_ids = [aws_security_group.database.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx mysql-server amazon-cloudwatch-agent

    # Inicia e habilita Apache
    systemctl start apache2
    systemctl enable apache2

    # Inicia e habilita Nginx
    systemctl start nginx
    systemctl enable nginx

    # Inicia e habilita MySQL
    systemctl start mysql
    systemctl enable mysql

    echo "<html><body><h1>Database AZ2 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Database AZ2 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html

    # Configuração do CloudWatch Agent para métricas de disco
    cat <<EOC > /opt/aws/amazon-cloudwatch-agent/bin/config.json
    {
      "metrics": {
        "namespace": "CWAgent",
        "metrics_collected": {
          "disk": {
            "measurement": [
              {"name": "disk_used_percent", "unit": "Percent"},
              {"name": "disk_used_bytes", "unit": "Bytes"}
            ],
            "resources": ["*"],
            "ignore_fs": ["tmpfs", "devtmpfs"]
          }
        }
      }
    }
    EOC

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s
  EOF
}

# ==============================================================================
# --- VOLUME EBS DO BANCO DE DADOS ---
# ==============================================================================
# Cria um volume gp3 criptografado de 20 GB e o anexa à instância do banco.

resource "aws_ebs_volume" "database_data" {
  availability_zone = aws_subnet.backend_az2.availability_zone
  size              = 20
  type              = "gp3"
  encrypted         = true

  tags = {
    Name = "${var.environment_name}-database-data"
  }
}

resource "aws_volume_attachment" "database_data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.database_data.id
  instance_id = aws_instance.database_az2.id
}

# ==============================================================================
# --- INSTÂNCIAS EC2 DO FRONTEND ---
# ==============================================================================
# Cria um frontend em cada zona e executa os scripts de inicialização.
# O user_data instala Apache, Nginx e React. (A SER ALTERADO)

resource "aws_instance" "web_az1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.web_az1.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx nodejs npm

    # Instala React globalmente
    npm install -g create-react-app

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    echo "<html><body><h1>Frontend AZ1 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Frontend AZ1 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

resource "aws_instance" "web_az2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.web_az2.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx nodejs npm

    # Instala React globalmente
    npm install -g create-react-app

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    echo "<html><body><h1>Frontend AZ2 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Frontend AZ2 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

# ==============================================================================
# --- NOTIFICAÇÕES DE ALERTA COM SNS ---
# ==============================================================================
# Cria o tópico de alertas e uma assinatura de e-mail ainda mockada.

resource "aws_sns_topic" "alerts" {
  name = "${var.environment_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "email.do.marcos@lamar.com" # endereço de email mockado
}

# ==============================================================================
# --- ALARME DE OCUPAÇÃO DO DISCO ---
# ==============================================================================
# Dispara o tópico SNS quando a métrica de uso do disco atingir 70%.

resource "aws_cloudwatch_metric_alarm" "ebs_used_percent" {
  alarm_name          = "${var.environment_name}-ebs-used-70-percent"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "disk_used_percent"
  namespace           = "CWAgent"
  period              = 60
  statistic           = "Average"
  threshold           = 70
  alarm_actions       = [aws_sns_topic.alerts.arn]
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = aws_instance.database_az2.id
    path       = "/var/lib/mysql"
    fstype     = "ext4"
  }
}

# ==============================================================================
# --- APPLICATION LOAD BALANCER ---
# ==============================================================================
# Cria o ALB público nas duas sub-redes públicas.

resource "aws_lb" "application" {
  name               = "${var.environment_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer.id]
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
}

# ==============================================================================
# --- TARGET GROUP DOS FRONTENDS ---
# ==============================================================================
# Agrupa as duas instâncias web e configura a verificação de saúde na raiz.

resource "aws_lb_target_group" "web" {
  name     = "${var.environment_name}-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
  }
}

resource "aws_lb_target_group_attachment" "web_az1" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_az1.id
  port             = 80
}

resource "aws_lb_target_group_attachment" "web_az2" {
  target_group_arn = aws_lb_target_group.web.arn
  target_id        = aws_instance.web_az2.id
  port             = 80
}

# ==============================================================================
# --- LISTENER HTTP DO LOAD BALANCER ---
# ==============================================================================
# Recebe conexões na porta 80 e as encaminha ao target group do frontend.

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

# ==============================================================================
# --- OUTPUTS DA INFRAESTRUTURA PRINCIPAL ---
# ==============================================================================
# Exibe o endereço do ALB e o IP privado atribuído à instância do banco.

output "application_url" {
  value = "http://${aws_lb.application.dns_name}"
}

output "database_private_ip" {
  value = aws_instance.database_az2.private_ip
}

# ==============================================================================
# --- DATA LAKE EM S3 ---
# ==============================================================================
# O conteúdo dos buckets vai ficar comentado porque já está gerado numa stack bem à parte.

/*
resource "aws_s3_bucket" "bronze" {
  bucket = "bronze-code-tracker"
}

resource "aws_s3_bucket_versioning" "bronze" {
  bucket = aws_s3_bucket.bronze.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "silver" {
  bucket = "silver-code-tracker"
}

resource "aws_s3_bucket_versioning" "silver" {
  bucket = aws_s3_bucket.silver.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket" "gold" {
  bucket = "gold-code-tracker"
}

resource "aws_s3_bucket_versioning" "gold" {
  bucket = aws_s3_bucket.gold.id

  versioning_configuration {
    status = "Enabled"
  }
}
*/

# ==============================================================================
# --- OUTPUTS DO DATA LAKE ---
# ==============================================================================
# Também serão comentados.

/*
output "bronze_bucket" {
  value = aws_s3_bucket.bronze.id
}

output "silver_bucket" {
  value = aws_s3_bucket.silver.id
}

output "gold_bucket" {
  value = aws_s3_bucket.gold.id
}
*/