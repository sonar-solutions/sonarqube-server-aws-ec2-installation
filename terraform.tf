terraform {
  required_version = ">= 1.9.0"

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
  jdbc_url           = "jdbc:postgresql://${aws_db_instance.postgres.address}:5432/${local.rds_database_name}"

  ami_lookup = {
    "amazon-linux-2023" = {
      owners  = ["amazon"]
      filters = {
        name                  = ["al2023-ami-2023.*-kernel-*-x86_64"]
        "virtualization-type" = ["hvm"]
      }
    }
    "windows-2025" = {
      owners  = ["801119661308"]
      filters = {
        name                  = ["Windows_Server-2025-English-Full-Base-*"]
        "virtualization-type" = ["hvm"]
      }
    }
  }

  # Map installation_os to AMI lookup key
  os_to_ami_key = {
    "linux"   = "amazon-linux-2023"
    "windows" = "windows-2025"
  }

  selected_ami_key = local.os_to_ami_key[var.installation_os]

  is_windows = var.installation_os == "windows"
}


data "aws_ami" "selected" {
  most_recent = true
  owners      = local.ami_lookup[local.selected_ami_key].owners

  dynamic "filter" {
    for_each = local.ami_lookup[local.selected_ami_key].filters
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
    description = "SonarQube from NLB"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = local.is_windows && var.enable_rdp ? [1] : []
    content {
      description = "RDP access"
      from_port   = 3389
      to_port     = 3389
      protocol    = "tcp"
      cidr_blocks = [var.rdp_allowed_cidr]
    }
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
  length         = 32
  special        = true
  override_special = "!#%^&*()_+-=[]{}|;:,.<>?"
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

resource "aws_launch_template" "app" {
  name_prefix            = "${local.sanitized_hostname}-"
  image_id               = data.aws_ami.selected.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.ec2.key_name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  dynamic "block_device_mappings" {
    for_each = var.deploy_agentic_containers ? [1] : []
    content {
      device_name = data.aws_ami.selected.root_device_name
      ebs {
        volume_size           = var.agentic_root_volume_size
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  user_data = base64encode(local.is_windows ? templatefile("${path.module}/user_data.ps1", {
    url              = var.zip_download_url
    path             = var.win_sonar_dir
    java_url         = var.win_java_url
    java_filename    = var.win_java_filename
    zip_filename     = var.zip_filename
    install_chromium = var.install_chromium
    jdbc_url         = local.jdbc_url
    db_password      = random_password.db_admin.result
    db_username      = var.db_username
  }) : templatefile("${path.module}/user_data.sh", {
    url          = var.zip_download_url
    path         = var.linux_sonar_dir
    zip_filename = var.zip_filename
    jdbc_url     = local.jdbc_url
    db_password  = random_password.db_admin.result
    db_username  = var.db_username
    deploy_agentic_containers  = var.deploy_agentic_containers
    agentic_generator_revision = var.agentic_generator_revision
    mcp_image                  = var.mcp_image
    aws_region                 = var.aws_region
    agentic_profile = jsonencode({
      edition        = "none"
      db_mode        = "external"
      db_host        = aws_db_instance.postgres.address
      db_port        = "5432"
      db_name        = local.rds_database_name
      db_user        = var.db_username
      db_password    = random_password.db_admin.result
      storage        = "hostpath"
      storage_path   = "${trimsuffix(var.linux_sonar_dir, "/")}/agentic-storage"
      tls            = "off"
      sandbox        = "runsc"
      llm_domains    = join(",", var.agentic_llm_domains)
      custom_ca_dir  = "./custom-ca"
      project_name   = "sonarqube-agentic"
    })
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = var.hostname
      Role        = "sonarqube-app"
      Domain      = local.domain_fqdn
      OperatingOS = var.installation_os
      Owner       = var.owner
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.sanitized_hostname}-asg"
  min_size                  = 1
  max_size                  = 1
  desired_capacity          = 1
  vpc_zone_identifier       = local.private_subnet_ids
  health_check_type         = "ELB"
  health_check_grace_period = var.deploy_agentic_containers ? 1800 : 600

  target_group_arns = concat(
    [aws_lb_target_group.app.arn],
    local.is_windows && var.enable_rdp ? [aws_lb_target_group.rdp[0].arn] : []
  )

  launch_template {
    id      = aws_launch_template.app.id
    version = tostring(aws_launch_template.app.latest_version)
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  depends_on = [aws_db_instance.postgres]

  tag {
    key                 = "Name"
    value               = var.hostname
    propagate_at_launch = true
  }
  tag {
    key                 = "Owner"
    value               = var.owner
    propagate_at_launch = true
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
  username                = "sonarqube"
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
  port        = 9000
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = local.vpc_id_effective

  health_check {
    port                = "9000"
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


resource "aws_lb_target_group" "rdp" {
  count = local.is_windows && var.enable_rdp ? 1 : 0

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


resource "aws_lb_listener" "rdp" {
  count = local.is_windows && var.enable_rdp ? 1 : 0

  load_balancer_arn = aws_lb.nlb.arn
  port              = 3389
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.rdp[0].arn
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

# Migrate state addresses from the removed ACM toggle's count-based resources.
# This preserves existing certificates and the HTTPS listener without recreating them.
moved {
  from = aws_acm_certificate.nlb[0]
  to   = aws_acm_certificate.nlb
}

moved {
  from = aws_acm_certificate_validation.nlb[0]
  to   = aws_acm_certificate_validation.nlb
}

moved {
  from = aws_lb_listener.tls[0]
  to   = aws_lb_listener.tls
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

output "sonarqube_url" {
  value       = "https://${local.domain_fqdn}"
  description = "Public URL to access the SonarQube instance."
}

output "asg_name" {
  value       = aws_autoscaling_group.app.name
  description = "Name of the Auto Scaling Group managing the SonarQube EC2 instance."
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