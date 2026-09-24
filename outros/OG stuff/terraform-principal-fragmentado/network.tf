# ==============================================================================
# VPC E INTERNET GATEWAY
# ==============================================================================

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/25"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# ==============================================================================
# SUB-REDES PÚBLICAS E PRIVADAS
# ==============================================================================

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
# ROTEAMENTO PÚBLICO
# ==============================================================================

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
# ELASTIC IPS E NAT GATEWAYS
# ==============================================================================

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
# ROTEAMENTO PRIVADO
# ==============================================================================

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
}
