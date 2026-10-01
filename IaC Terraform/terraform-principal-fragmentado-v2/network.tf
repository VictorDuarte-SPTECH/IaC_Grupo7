# ==============================================================================
# VPC E INTERNET GATEWAY
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/25"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.environment_name}-vpc-principal"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.environment_name}-gateway-internet"
  }
}

# ==============================================================================
# SUB-REDES PÚBLICAS E PRIVADAS
# ==============================================================================

resource "aws_subnet" "public_az1" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = "10.0.0.0/27"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment_name}-subnet-publica-az1"
  }
}

resource "aws_subnet" "public_az2" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[1]
  cidr_block              = "10.0.0.32/27"
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment_name}-subnet-publica-az2"
  }
}

resource "aws_subnet" "web_az1" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = "10.0.0.64/28"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-subnet-web-az1"
  }
}

resource "aws_subnet" "web_az2" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[1]
  cidr_block              = "10.0.0.80/28"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-subnet-web-az2"
  }
}

resource "aws_subnet" "backend_az1" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = "10.0.0.96/28"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-subnet-backend-az1"
  }
}

resource "aws_subnet" "backend_az2" {
  vpc_id                  = aws_vpc.main.id
  availability_zone       = data.aws_availability_zones.available.names[1]
  cidr_block              = "10.0.0.112/28"
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.environment_name}-subnet-backend-az2"
  }
}

# ==============================================================================
# ROTEAMENTO PÚBLICO
# ==============================================================================

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.environment_name}-tabela-rotas-publica"
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
# ELASTIC IPS E NAT GATEWAYS
# ==============================================================================

resource "aws_eip" "nat_az1" {
  domain = "vpc"

  tags = {
    Name = "${var.environment_name}-ip-elastico-nat-az1"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_eip" "nat_az2" {
  domain = "vpc"

  tags = {
    Name = "${var.environment_name}-ip-elastico-nat-az2"
  }

  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "az1" {
  allocation_id = aws_eip.nat_az1.id
  subnet_id     = aws_subnet.public_az1.id

  tags = {
    Name = "${var.environment_name}-gateway-nat-az1"
  }
}

resource "aws_nat_gateway" "az2" {
  allocation_id = aws_eip.nat_az2.id
  subnet_id     = aws_subnet.public_az2.id

  tags = {
    Name = "${var.environment_name}-gateway-nat-az2"
  }
}

# ==============================================================================
# ROTEAMENTO PRIVADO
# ==============================================================================

resource "aws_route_table" "private_az1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.az1.id
  }

  tags = {
    Name = "${var.environment_name}-tabela-rotas-privada-az1"
  }
}

resource "aws_route_table" "private_az2" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.az2.id
  }

  tags = {
    Name = "${var.environment_name}-tabela-rotas-privada-az2"
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
# SECURITY GROUP DO APPLICATION LOAD BALANCER
# ==============================================================================

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

  tags = {
    Name = "${var.environment_name}-sg-alb"
  }
}

# ==============================================================================
# SECURITY GROUP DO FRONTEND
# ==============================================================================

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

  tags = {
    Name = "${var.environment_name}-sg-web"
  }
}

# ==============================================================================
# SECURITY GROUP DO BACKEND
# ==============================================================================

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

  tags = {
    Name = "${var.environment_name}-sg-backend"
  }
}

# ==============================================================================
# SECURITY GROUP DO BANCO DE DADOS
# ==============================================================================

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

  tags = {
    Name = "${var.environment_name}-sg-banco"
  }
}

# ==============================================================================
# SECURITY GROUPS DE ACESSO, SWARM E RABBITMQ
# ==============================================================================

resource "aws_security_group" "bastion" {
  name_prefix = "${var.environment_name}-bastion-"
  description = "Permite SSH da estacao administrativa ao bastion"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-sg-bastion"
  }
}

resource "aws_security_group" "private_ssh" {
  name_prefix = "${var.environment_name}-ssh-privado-"
  description = "Permite SSH e SFTP nas instancias privadas somente pelo bastion"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-sg-ssh-privado"
  }
}

resource "aws_security_group" "swarm" {
  name_prefix = "${var.environment_name}-docker-swarm-"
  description = "Permite comunicacao interna entre os nos Docker Swarm"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port = 2377
    to_port   = 2377
    protocol  = "tcp"
    self      = true
  }

  ingress {
    from_port = 7946
    to_port   = 7946
    protocol  = "tcp"
    self      = true
  }

  ingress {
    from_port = 7946
    to_port   = 7946
    protocol  = "udp"
    self      = true
  }

  ingress {
    from_port = 4789
    to_port   = 4789
    protocol  = "udp"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-sg-docker-swarm"
  }
}

resource "aws_security_group" "rabbitmq" {
  name_prefix = "${var.environment_name}-rabbitmq-"
  description = "Permite AMQP somente a partir dos backends"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment_name}-sg-rabbitmq"
  }
}
