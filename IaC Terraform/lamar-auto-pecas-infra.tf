terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

provider "aws" {
  region = var.aws_region
}

variable "environment_name" {
  type    = string
  default = "lamar-auto-pecas"
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "ubuntu_ami" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/25"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

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

resource "aws_sns_topic" "alerts" {
  name = "${var.environment_name}-alerts"
}

resource "aws_sns_topic_subscription" "alerts_email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "email.do.marcos@lamar.com" # endereço de email mockado
}

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

resource "aws_lb" "application" {
  name               = "${var.environment_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer.id]
  subnets            = [aws_subnet.public_az1.id, aws_subnet.public_az2.id]
}

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

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.application.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

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

output "application_url" {
  value = "http://${aws_lb.application.dns_name}"
}

output "database_private_ip" {
  value = aws_instance.database_az2.private_ip
}

output "bronze_bucket" {
  value = aws_s3_bucket.bronze.id
}

output "silver_bucket" {
  value = aws_s3_bucket.silver.id
}

output "gold_bucket" {
  value = aws_s3_bucket.gold.id
}