# ==============================================================================
# BASTION E MANAGER DO DOCKER SWARM
# ==============================================================================

resource "aws_instance" "bastion" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  key_name                    = var.key_name

  tags = {
    Name = "${var.environment_name}-vm-bastion-az1"
  }
}

resource "aws_eip" "bastion" {
  domain   = "vpc"
  instance = aws_instance.bastion.id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "${var.environment_name}-ip-elastico-bastion"
  }
}

resource "aws_instance" "swarm_manager" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.private_ssh.id, aws_security_group.swarm.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  depends_on = [aws_route_table_association.backend_az1]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl docker.io openssh-server

    hostnamectl set-hostname swarm-manager-az1
    systemctl enable docker
    systemctl restart docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    IMDS_TOKEN=$(curl --fail --silent --show-error --request PUT \
      --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)
    PRIVATE_IP=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/meta-data/local-ipv4)
    REGION=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/dynamic/instance-identity/document \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["region"])')

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
      docker swarm init --advertise-addr "$PRIVATE_IP"
    fi

    MANAGER_NODE_ID=$(docker info --format '{{.Swarm.NodeID}}')
    docker node update \
      --availability drain \
      --label-add tier=manager \
      --label-add zone=az1 \
      "$MANAGER_NODE_ID"

    WORKER_TOKEN=$(docker swarm join-token --quiet worker)
    aws ssm put-parameter \
      --region "$REGION" \
      --name '/${var.environment_name}/swarm/worker-token' \
      --type SecureString \
      --value "$WORKER_TOKEN" \
      --overwrite

    cat > /usr/local/sbin/label-swarm-workers <<'SCRIPT'
    #!/bin/bash
    set -euo pipefail

    ALL_WORKERS_READY=true

    while read -r NODE_NAME TIER ZONE; do
      NODE_ID=$(docker node ls --filter "name=$NODE_NAME" --format '{{.ID}}' | head -n 1)

      if [ -z "$NODE_ID" ]; then
        ALL_WORKERS_READY=false
        continue
      fi

      docker node update \
        --label-add "tier=$TIER" \
        --label-add "zone=$ZONE" \
        "$NODE_ID"
    done <<'NODES'
    web-az1 web az1
    web-az2 web az2
    backend-az1 backend az1
    backend-az2 backend az2
    NODES

    if [ "$ALL_WORKERS_READY" != true ]; then
      exit 1
    fi
    SCRIPT

    chmod 750 /usr/local/sbin/label-swarm-workers

    cat > /etc/systemd/system/label-swarm-workers.service <<'SERVICE'
    [Unit]
    Description=Aplica labels aos workers do Docker Swarm
    After=docker.service
    Requires=docker.service
    StartLimitIntervalSec=0

    [Service]
    Type=oneshot
    ExecStart=/usr/local/sbin/label-swarm-workers
    Restart=on-failure
    RestartSec=15

    [Install]
    WantedBy=multi-user.target
    SERVICE

    systemctl daemon-reload
    systemctl enable label-swarm-workers.service
    systemctl start label-swarm-workers.service || true
  EOF

  tags = {
    Name = "${var.environment_name}-vm-swarm-manager-az1"
  }
}

# ==============================================================================
# INSTÂNCIAS EC2 DO BACKEND
# ==============================================================================

resource "aws_instance" "backend_az1" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.backend.id, aws_security_group.private_ssh.id, aws_security_group.swarm.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl docker.io openssh-server

    hostnamectl set-hostname backend-az1
    systemctl enable docker
    systemctl restart docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    IMDS_TOKEN=$(curl --fail --silent --show-error --request PUT \
      --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)
    REGION=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/dynamic/instance-identity/document \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["region"])')

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
      for attempt in $(seq 1 90); do
        if WORKER_TOKEN=$(aws ssm get-parameter \
          --region "$REGION" \
          --name '/${var.environment_name}/swarm/worker-token' \
          --with-decryption \
          --query Parameter.Value \
          --output text 2>/dev/null); then
          if docker swarm join \
            --token "$WORKER_TOKEN" \
            '${aws_instance.swarm_manager.private_ip}:2377'; then
            break
          fi
        fi

        sleep 10
      done
    fi

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "Nao foi possivel adicionar backend-az1 ao Docker Swarm." >&2
      exit 1
    fi
  EOF

  tags = {
    Name = "${var.environment_name}-vm-backend-az1"
  }
}

resource "aws_instance" "backend_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.backend.id, aws_security_group.private_ssh.id, aws_security_group.swarm.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl docker.io openssh-server

    hostnamectl set-hostname backend-az2
    systemctl enable docker
    systemctl restart docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    IMDS_TOKEN=$(curl --fail --silent --show-error --request PUT \
      --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)
    REGION=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/dynamic/instance-identity/document \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["region"])')

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
      for attempt in $(seq 1 90); do
        if WORKER_TOKEN=$(aws ssm get-parameter \
          --region "$REGION" \
          --name '/${var.environment_name}/swarm/worker-token' \
          --with-decryption \
          --query Parameter.Value \
          --output text 2>/dev/null); then
          if docker swarm join \
            --token "$WORKER_TOKEN" \
            '${aws_instance.swarm_manager.private_ip}:2377'; then
            break
          fi
        fi

        sleep 10
      done
    fi

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "Nao foi possivel adicionar backend-az2 ao Docker Swarm." >&2
      exit 1
    fi
  EOF

  tags = {
    Name = "${var.environment_name}-vm-backend-az2"
  }
}

# ==============================================================================
# INSTÂNCIA EC2 DO RABBITMQ
# ==============================================================================

resource "aws_instance" "rabbitmq" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az1.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.rabbitmq.id, aws_security_group.private_ssh.id]
  key_name                    = var.key_name
  user_data_replace_on_change = true

  depends_on = [aws_route_table_association.backend_az1]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io openssh-server

    hostnamectl set-hostname rabbitmq-az1
    systemctl enable --now docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    docker volume create rabbitmq-data
    docker run --detach \
      --name rabbitmq \
      --hostname rabbitmq \
      --restart unless-stopped \
      --publish 5672:5672 \
      --publish 15672:15672 \
      --health-cmd 'rabbitmq-diagnostics -q ping' \
      --health-interval 30s \
      --health-timeout 10s \
      --health-retries 5 \
      --env RABBITMQ_DEFAULT_USER='${var.rabbitmq_user}' \
      --env RABBITMQ_DEFAULT_PASS='${var.rabbitmq_password}' \
      --volume rabbitmq-data:/var/lib/rabbitmq \
      rabbitmq:4-management-alpine
  EOF

  tags = {
    Name = "${var.environment_name}-vm-rabbitmq-az1"
  }
}

# ==============================================================================
# INSTÂNCIA EC2 DO BANCO DE DADOS
# ==============================================================================

resource "aws_instance" "database_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.backend_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.database.id, aws_security_group.private_ssh.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io

    systemctl enable --now docker
    usermod -aG docker ubuntu

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
      echo "O volume EBS nao foi encontrado apos 300 segundos." >&2
      exit 1
    fi

    if ! blkid "$DEVICE" >/dev/null 2>&1; then
      mkfs.ext4 "$DEVICE"
    fi

    EBS_UUID=$(blkid -s UUID -o value "$DEVICE")
    mkdir -p /var/lib/mysql

    if ! grep -q "UUID=$EBS_UUID /var/lib/mysql " /etc/fstab; then
      echo "UUID=$EBS_UUID /var/lib/mysql ext4 defaults,nofail 0 2" >> /etc/fstab
    fi

    mountpoint -q /var/lib/mysql || mount /var/lib/mysql

    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server
    systemctl enable --now mysql

    cat > /etc/mysql/mysql.conf.d/99-lamar-network.cnf <<'MYSQL_CONFIG'
    [mysqld]
    bind-address = 0.0.0.0
    mysqlx-bind-address = 127.0.0.1
    MYSQL_CONFIG

    systemctl restart mysql

    mysql <<'SQL'
    CREATE DATABASE IF NOT EXISTS `${var.database_name}`;
    CREATE USER IF NOT EXISTS '${var.database_user}'@'10.0.0.%' IDENTIFIED BY '${var.database_password}';
    ALTER USER '${var.database_user}'@'10.0.0.%' IDENTIFIED BY '${var.database_password}';
    GRANT ALL PRIVILEGES ON `${var.database_name}`.* TO '${var.database_user}'@'10.0.0.%';
    FLUSH PRIVILEGES;
    SQL
  EOF

  tags = {
    Name = "${var.environment_name}-vm-banco-az2"
  }
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
    Name = "${var.environment_name}-volume-dados-banco-az2"
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
  vpc_security_group_ids      = [aws_security_group.web.id, aws_security_group.private_ssh.id, aws_security_group.swarm.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl docker.io openssh-server

    hostnamectl set-hostname web-az1
    systemctl enable docker
    systemctl restart docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    IMDS_TOKEN=$(curl --fail --silent --show-error --request PUT \
      --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)
    REGION=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/dynamic/instance-identity/document \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["region"])')

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
      for attempt in $(seq 1 90); do
        if WORKER_TOKEN=$(aws ssm get-parameter \
          --region "$REGION" \
          --name '/${var.environment_name}/swarm/worker-token' \
          --with-decryption \
          --query Parameter.Value \
          --output text 2>/dev/null); then
          if docker swarm join \
            --token "$WORKER_TOKEN" \
            '${aws_instance.swarm_manager.private_ip}:2377'; then
            break
          fi
        fi

        sleep 10
      done
    fi

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "Nao foi possivel adicionar web-az1 ao Docker Swarm." >&2
      exit 1
    fi
  EOF

  tags = {
    Name = "${var.environment_name}-vm-web-az1"
  }
}

resource "aws_instance" "web_az2" {
  ami                         = data.aws_ssm_parameter.ubuntu_ami.value
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.web_az2.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.web.id, aws_security_group.private_ssh.id, aws_security_group.swarm.id]
  iam_instance_profile        = var.instance_profile_name
  key_name                    = var.key_name
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y awscli curl docker.io openssh-server

    hostnamectl set-hostname web-az2
    systemctl enable docker
    systemctl restart docker
    systemctl enable --now ssh
    usermod -aG docker ubuntu

    IMDS_TOKEN=$(curl --fail --silent --show-error --request PUT \
      --header "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
      http://169.254.169.254/latest/api/token)
    REGION=$(curl --fail --silent --show-error \
      --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
      http://169.254.169.254/latest/dynamic/instance-identity/document \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["region"])')

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = "inactive" ]; then
      for attempt in $(seq 1 90); do
        if WORKER_TOKEN=$(aws ssm get-parameter \
          --region "$REGION" \
          --name '/${var.environment_name}/swarm/worker-token' \
          --with-decryption \
          --query Parameter.Value \
          --output text 2>/dev/null); then
          if docker swarm join \
            --token "$WORKER_TOKEN" \
            '${aws_instance.swarm_manager.private_ip}:2377'; then
            break
          fi
        fi

        sleep 10
      done
    fi

    if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then
      echo "Nao foi possivel adicionar web-az2 ao Docker Swarm." >&2
      exit 1
    fi
  EOF

  tags = {
    Name = "${var.environment_name}-vm-web-az2"
  }
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

  tags = {
    Name = "${var.environment_name}-alb"
  }
}

resource "aws_lb_target_group" "web" {
  name     = "${var.environment_name}-web-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path = "/"
  }

  tags = {
    Name = "${var.environment_name}-grupo-destino-web"
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
