# ==============================================================================
# INSTÂNCIAS EC2 DO BACKEND
# ==============================================================================
# O Docker é instalado e habilitado, mas nenhum container é iniciado nesta etapa.
# Apache e Nginx foram preservados para a limpeza posterior do user_data.

resource "aws_instance" "backend_az1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.backend_az1.id
  vpc_security_group_ids = [aws_security_group.backend.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx docker.io

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    systemctl enable --now docker
    usermod -aG docker ubuntu

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
    apt-get install -y apache2 nginx docker.io

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    systemctl enable --now docker
    usermod -aG docker ubuntu

    echo "<html><body><h1>Backend AZ2 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Backend AZ2 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

# ==============================================================================
# INSTÂNCIA EC2 DO BANCO DE DADOS
# ==============================================================================

resource "aws_instance" "database_az2" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.backend_az2.id
  vpc_security_group_ids = [aws_security_group.database.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y docker.io

    # Prepara a instância para executar containers posteriormente
    systemctl enable --now docker
    usermod -aG docker ubuntu

    # Instalações originais preservadas para a etapa posterior de limpeza
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
# VOLUME EBS DO BANCO DE DADOS
# ==============================================================================

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
# INSTÂNCIAS EC2 DO FRONTEND
# ==============================================================================

resource "aws_instance" "web_az1" {
  ami                    = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.web_az1.id
  vpc_security_group_ids = [aws_security_group.web.id]

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y apache2 nginx nodejs npm docker.io

    # Instala React globalmente
    npm install -g create-react-app

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    systemctl enable --now docker
    usermod -aG docker ubuntu

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
    apt-get install -y apache2 nginx nodejs npm docker.io

    # Instala React globalmente
    npm install -g create-react-app

    systemctl start apache2
    systemctl enable apache2
    systemctl start nginx
    systemctl enable nginx

    systemctl enable --now docker
    usermod -aG docker ubuntu

    echo "<html><body><h1>Frontend AZ2 - Apache</h1></body></html>" > /var/www/html/index.html
    echo "<html><body><h1>Frontend AZ2 - Nginx</h1></body></html>" > /var/www/html/index.nginx.html
  EOF
}

# ==============================================================================
# APPLICATION LOAD BALANCER E TARGET GROUP DO FRONTEND
# ==============================================================================

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
