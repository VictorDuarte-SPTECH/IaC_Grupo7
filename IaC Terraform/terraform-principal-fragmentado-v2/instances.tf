# ==============================================================================
# INSTÂNCIAS EC2 DO BACKEND
# ==============================================================================
# O Docker é instalado e habilitado, mas nenhum container é iniciado nesta etapa.

resource "aws_instance" "backend_az1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.backend.id]
  iam_instance_profile        = var.instance_profile_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

    systemctl enable --now docker
    usermod -aG docker ubuntu
  EOF
}

resource "aws_instance" "backend_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.backend.id]
  iam_instance_profile        = var.instance_profile_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

    systemctl enable --now docker
    usermod -aG docker ubuntu
  EOF
}

# ==============================================================================
# INSTÂNCIA EC2 DO BANCO DE DADOS
# ==============================================================================

resource "aws_instance" "database_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.database.id]
  iam_instance_profile        = var.instance_profile_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl

    systemctl enable --now docker
    usermod -aG docker ubuntu

    # Aguarda o EBS ser anexado. Em instâncias Nitro, /dev/sdf aparece como NVMe.
    EBS_VOLUME_ID="${replace(aws_ebs_volume.database_data.id, "-", "")}"
    DEVICE=""

    for attempt in $(seq 1 60); do
      for candidate in "/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_$EBS_VOLUME_ID" /dev/xvdf /dev/sdf; do
        if [ -b "$candidate" ]; then
          DEVICE="$candidate"
          break 2
        fi
      done
      sleep 5
    done

    if [ -z "$DEVICE" ]; then
      echo "O volume EBS não foi encontrado após 300 segundos." >&2
      exit 1
    fi

    # Formata apenas volumes novos e mantém a montagem após reinicializações.
    if ! blkid "$DEVICE" >/dev/null 2>&1; then
      mkfs.ext4 "$DEVICE"
    fi

    EBS_UUID=$(blkid -s UUID -o value "$DEVICE")
    mkdir -p /var/lib/mysql

    if ! grep -q "UUID=$EBS_UUID /var/lib/mysql " /etc/fstab; then
      echo "UUID=$EBS_UUID /var/lib/mysql ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    mountpoint -q /var/lib/mysql || mount /var/lib/mysql

    # Instala o MySQL diretamente sobre o volume EBS montado.
    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
    systemctl enable --now mysql

    # Instala o pacote oficial do CloudWatch Agent para Ubuntu.
    curl -fsSL \
      https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb \
      -o /tmp/amazon-cloudwatch-agent.deb
    dpkg -i /tmp/amazon-cloudwatch-agent.deb

    cat <<'EOC' > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
    {
      "agent": {
        "metrics_collection_interval": 60,
        "omit_hostname": true
      },
      "metrics": {
        "namespace": "CWAgent",
        "append_dimensions": {
          "InstanceId": "$${aws:InstanceId}"
        },
        "metrics_collected": {
          "disk": {
            "measurement": ["used_percent"],
            "resources": ["/var/lib/mysql"],
            "drop_device": true,
            "ignore_file_system_types": ["tmpfs", "devtmpfs"]
          }
        }
      }
    }
    EOC

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config \
      -m ec2 \
      -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
      -s
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
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.web_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = var.instance_profile_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

    systemctl enable --now docker
    usermod -aG docker ubuntu
  EOF
}

resource "aws_instance" "web_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.web_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.web.id]
  iam_instance_profile        = var.instance_profile_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

    systemctl enable --now docker
    usermod -aG docker ubuntu
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
