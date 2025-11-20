terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

locals {
  create_vpc         = var.vpc_id == null || trimspace(var.vpc_id) == ""
  sanitized_hostname = lower(replace(var.hostname, "/[^a-z0-9-]/", "-"))
  load_balancer_name = substr(local.sanitized_hostname, 0, 32)
  target_group_name  = substr("${local.sanitized_hostname}-tg", 0, 32)
  rdp_target_group_name = substr("${local.sanitized_hostname}-rdp-tg", 0, 32)
  domain_fqdn        = format("%s.%s", var.hostname, trim(var.domain_name, "."))
  rds_identifier     = substr(replace(lower(var.rds_name), "/[^a-z0-9-]/", "-"), 0, 63)
  rds_database_name  = substr(replace(lower(var.rds_name), "/[^a-z0-9]/", ""), 0, 63)

  ami_lookup = {
    "amazon-linux-2" = {
      owners  = ["amazon"]
      filters = {
        name                  = ["amzn2-ami-hvm-*-x86_64-gp2"]
        "virtualization-type" = ["hvm"]
      }
    }
    "windows-2019" = {
      owners  = ["801119661308"]
      filters = {
        name                  = ["Windows_Server-2019-English-Full-Base-*"]
        "virtualization-type" = ["hvm"]
      }
    }
  }
}


data "aws_ami" "selected" {
  most_recent = true
  owners      = local.ami_lookup[var.operating_system].owners

  dynamic "filter" {
    for_each = local.ami_lookup[var.operating_system].filters
    content {
      name   = filter.key
      values = filter.value
    }
  }
}

resource "aws_vpc" "this" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpn_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name  = var.vpc_name
    Owner = var.owner
  }

  lifecycle {
    precondition {
      condition     = var.vpc_name != null && trimspace(var.vpc_name) != ""
      error_message = "vpc_name must be provided when creating a new VPC."
    }
    precondition {
      condition     = var.vpn_cidr != null && trimspace(var.vpn_cidr) != ""
      error_message = "vpn_cidr must be provided when creating a new VPC."
    }
    precondition {
      condition     = var.public_subnets != null && length(var.public_subnets) > 0
      error_message = "public_subnets must be provided when creating a new VPC for the internet-facing NLB."
    }
  }
}

locals {
  vpc_id_effective = local.create_vpc ? aws_vpc.this[0].id : var.vpc_id
  az_to_cidr       = local.create_vpc ? zipmap(var.availability_zones, var.private_subnets) : {}
  az_to_public_cidr = local.create_vpc ? zipmap(var.availability_zones, var.public_subnets) : {}
}

resource "aws_subnet" "private" {
  for_each = local.az_to_cidr

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = {
    Name  = format("%s-private-%s", var.vpc_name, each.key)
    Owner = var.owner
  }
}

resource "aws_subnet" "public" {
  for_each = local.az_to_public_cidr

  vpc_id                  = aws_vpc.this[0].id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = true

  tags = {
    Name  = format("%s-public-%s", var.vpc_name, each.key)
    Owner = var.owner
  }
}

resource "aws_internet_gateway" "this" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  tags = {
    Name  = format("%s-igw", var.vpc_name)
    Owner = var.owner
  }
}

resource "aws_route_table" "public" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = {
    Name  = format("%s-public-rt", var.vpc_name)
    Owner = var.owner
  }
}

resource "aws_route_table_association" "public" {
  for_each = local.az_to_public_cidr

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count = local.create_vpc ? 1 : 0

  domain = "vpc"

  tags = {
    Name  = format("%s-nat-eip", var.vpc_name)
    Owner = var.owner
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.create_vpc ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = local.create_vpc ? [for subnet in values(aws_subnet.public) : subnet.id][0] : null

  tags = {
    Name  = format("%s-nat", var.vpc_name)
    Owner = var.owner
  }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.this[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[0].id
  }

  tags = {
    Name  = format("%s-private-rt", var.vpc_name)
    Owner = var.owner
  }
}

resource "aws_route_table_association" "private" {
  for_each = local.az_to_cidr

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[0].id
}

locals {
  private_subnet_ids = local.create_vpc ? [for subnet in values(aws_subnet.private) : subnet.id] : var.private_subnets
  public_subnet_ids  = local.create_vpc ? [for subnet in values(aws_subnet.public) : subnet.id] : (var.public_subnets != null ? var.public_subnets : var.private_subnets)
  primary_subnet_id  = local.private_subnet_ids[0]
}

resource "aws_security_group" "ec2" {
  name        = substr("${local.sanitized_hostname}-ec2-sg", 0, 128)
  description = "Allow TLS from NLB and DB egress"
  vpc_id      = local.vpc_id_effective

  ingress {
    description = "TLS from NLB"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "RDP access"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = [var.rdp_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "${local.sanitized_hostname}-ec2"
    Owner = var.owner
  }
}

resource "aws_security_group" "db" {
  name        = substr("${local.rds_identifier}-db-sg", 0, 128)
  description = "Allow PostgreSQL from application instances"
  vpc_id      = local.vpc_id_effective

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name  = "${local.rds_identifier}-db"
    Owner = var.owner
  }
}

resource "aws_security_group_rule" "db_from_ec2" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.ec2.id
  description              = "PostgreSQL from EC2"
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.rds_identifier}-subnets"
  subnet_ids = local.private_subnet_ids

  tags = {
    Name  = "${local.rds_identifier}-subnets"
    Owner = var.owner
  }
}

resource "random_password" "db_admin" {
  length  = 32
  special = true
}

resource "tls_private_key" "ec2_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2" {
  key_name   = "${local.sanitized_hostname}-key"
  public_key = tls_private_key.ec2_key.public_key_openssh

  tags = {
    Name  = "${local.sanitized_hostname}-key"
    Owner = var.owner
  }
}

resource "local_file" "private_key" {
  content         = tls_private_key.ec2_key.private_key_pem
  filename        = "${local.sanitized_hostname}-key.pem"
  file_permission = "0600"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ami.selected.id
  instance_type               = var.instance_type
  subnet_id                   = local.primary_subnet_id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  key_name                    = aws_key_pair.ec2.key_name
  associate_public_ip_address = false

  tags = {
    Name        = var.hostname
    Role        = "sonarqube-app"
    Domain      = local.domain_fqdn
    OperatingOS = var.operating_system
    Owner       = var.owner
  }
}

resource "aws_db_instance" "postgres" {
  identifier              = local.rds_identifier
  db_name                 = local.rds_database_name
  engine                  = "postgres"
  engine_version          = var.rds_engine_version
  instance_class          = var.rds_instance_type
  allocated_storage       = 50
  storage_encrypted       = true
  multi_az                = length(local.private_subnet_ids) > 1
  db_subnet_group_name    = aws_db_subnet_group.this.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  username                = "sqadmin"
  password                = random_password.db_admin.result
  publicly_accessible     = false
  backup_retention_period = 7
  deletion_protection     = false
  skip_final_snapshot     = true
  apply_immediately       = true

  tags = {
    Name  = local.rds_identifier
    Owner = var.owner
  }
}

resource "aws_lb" "nlb" {
  name               = local.load_balancer_name
  internal           = false
  load_balancer_type = "network"
  subnets            = local.public_subnet_ids
  enable_cross_zone_load_balancing = true

  tags = {
    Name  = local.load_balancer_name
    Owner = var.owner
  }
}

resource "aws_lb_target_group" "app" {
  name        = local.target_group_name
  port        = 443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = local.vpc_id_effective

  health_check {
    port                = "443"
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name  = "${local.load_balancer_name}-tg"
    Owner = var.owner
  }
}

resource "aws_lb_target_group_attachment" "app_ec2" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app.id
  port             = 443
}

resource "aws_lb_target_group" "rdp" {
  name        = local.rdp_target_group_name
  port        = 3389
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = local.vpc_id_effective

  health_check {
    port                = "3389"
    protocol            = "TCP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = {
    Name  = "${local.load_balancer_name}-rdp-tg"
    Owner = var.owner
  }
}

resource "aws_lb_target_group_attachment" "rdp_ec2" {
  target_group_arn = aws_lb_target_group.rdp.arn
  target_id        = aws_instance.app.id
  port             = 3389
}

resource "aws_lb_listener" "rdp" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 3389
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rdp.arn
  }
}

data "aws_route53_zone" "primary" {
  name         = "${trim(var.domain_name, ".")}."
  private_zone = false
}

resource "aws_acm_certificate" "nlb" {
  domain_name       = local.domain_fqdn
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name  = local.domain_fqdn
    Owner = var.owner
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.nlb.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  allow_overwrite = true
  zone_id         = data.aws_route53_zone.primary.zone_id
  name            = each.value.name
  type            = each.value.type
  ttl             = 300
  records         = [each.value.record]
}

resource "aws_acm_certificate_validation" "nlb" {
  certificate_arn         = aws_acm_certificate.nlb.arn
  validation_record_fqdns = [for record in values(aws_route53_record.cert_validation) : record.fqdn]
}

resource "aws_lb_listener" "tls" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.nlb.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  depends_on = [aws_acm_certificate_validation.nlb]
}

resource "aws_route53_record" "app_alias" {
  zone_id = data.aws_route53_zone.primary.zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.nlb.dns_name
    zone_id                = aws_lb.nlb.zone_id
    evaluate_target_health = true
  }
}

output "ec2_instance_id" {
  value       = aws_instance.app.id
  description = "ID of the SonarQube EC2 instance."
}

output "ec2_private_ip" {
  value       = aws_instance.app.private_ip
  description = "Private IP address of the SonarQube EC2 instance."
}

output "rds_endpoint" {
  value       = aws_db_instance.postgres.address
  description = "Endpoint of the PostgreSQL RDS instance."
}

output "nlb_dns_name" {
  value       = aws_lb.nlb.dns_name
  description = "Network Load Balancer DNS name."
}

output "rds_master_password" {
  value       = random_password.db_admin.result
  description = "Generated master password for the PostgreSQL instance."
  sensitive   = true
}

output "key_pair_name" {
  value       = aws_key_pair.ec2.key_name
  description = "Name of the EC2 key pair."
}

output "private_key_path" {
  value       = local_file.private_key.filename
  description = "Path to the saved private key file. Use this key to decrypt the Windows Administrator password."
}