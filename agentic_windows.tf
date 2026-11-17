locals {
  hybrid_agentic = local.is_windows && var.deploy_agentic_containers
  agentic_fqdn   = "agentic.${local.domain_fqdn}"
  hybrid_roles   = local.hybrid_agentic ? toset(["app", "agents"]) : toset([])
}

data "aws_ami" "agents" {
  count       = local.hybrid_agentic ? 1 : 0
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = local.ami_lookup["amazon-linux-2023"].filters.name
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_s3_bucket" "hybrid" {
  for_each      = local.hybrid_agentic ? toset(["bootstrap", "jobs"]) : toset([])
  bucket_prefix = "${substr(local.sanitized_hostname, 0, 20)}-${each.key}-"
  force_destroy = false
  tags = {
    Owner = var.owner
    Role  = "sonarqube-agentic-${each.key}"
  }
}

resource "aws_s3_bucket_public_access_block" "hybrid" {
  for_each                = aws_s3_bucket.hybrid
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "hybrid" {
  for_each = aws_s3_bucket.hybrid
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "hybrid" {
  for_each = aws_s3_bucket.hybrid
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [each.value.arn, "${each.value.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_user" "agentic_storage" {
  count = local.hybrid_agentic ? 1 : 0
  name  = "${substr(local.sanitized_hostname, 0, 48)}-agentic-storage"
  tags  = { Owner = var.owner }
}

resource "aws_iam_access_key" "agentic_storage" {
  count = local.hybrid_agentic ? 1 : 0
  user  = aws_iam_user.agentic_storage[0].name
}

resource "aws_iam_user_policy" "agentic_storage" {
  count = local.hybrid_agentic ? 1 : 0
  user  = aws_iam_user.agentic_storage[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.hybrid["jobs"].arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.hybrid["jobs"].arn}/*" }
    ]
  })
}

resource "aws_iam_role" "hybrid" {
  for_each    = local.hybrid_roles
  name_prefix = "${substr(local.sanitized_hostname, 0, 20)}-${each.key}-"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = { Owner = var.owner }
}

resource "aws_iam_instance_profile" "hybrid" {
  for_each = local.hybrid_roles
  role     = aws_iam_role.hybrid[each.key].name
}

resource "aws_iam_role_policy" "hybrid" {
  for_each = local.hybrid_roles
  role     = aws_iam_role.hybrid[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = each.key == "app" ? [
          "${aws_s3_bucket.hybrid["bootstrap"].arn}/windows.ps1",
          "${aws_s3_bucket.hybrid["bootstrap"].arn}/windows-config.json"
        ] : ["${aws_s3_bucket.hybrid["bootstrap"].arn}/identity.json"]
      }
      ], each.key == "agents" ? [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [aws_s3_bucket.hybrid["bootstrap"].arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.hybrid["bootstrap"].arn}/identity.json", "${aws_s3_bucket.hybrid["bootstrap"].arn}/windows-config.json"]
      }
    ] : [])
  })
}

resource "aws_security_group" "agents" {
  count       = local.hybrid_agentic ? 1 : 0
  name_prefix = "${local.sanitized_hostname}-agents-"
  description = "Private agent TLS endpoints from the Windows application"
  vpc_id      = local.vpc_id_effective
  ingress {
    from_port       = 8443
    to_port         = 8445
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Owner = var.owner }
}

resource "aws_security_group_rule" "db_from_agents" {
  count                    = local.hybrid_agentic ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.db.id
  source_security_group_id = aws_security_group.agents[0].id
  description              = "PostgreSQL from the hybrid agent host"
}

resource "aws_security_group" "hybrid_nlb" {
  count       = local.hybrid_agentic ? 1 : 0
  name_prefix = "${local.sanitized_hostname}-private-nlb-"
  description = "Private TLS callbacks from the Linux agent host"
  vpc_id      = local.vpc_id_effective
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.agents[0].id]
  }
  egress {
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }
  tags = { Owner = var.owner }
}

resource "aws_lb" "hybrid" {
  count                            = local.hybrid_agentic ? 1 : 0
  name_prefix                      = "sq-p-"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = local.private_subnet_ids
  security_groups                  = [aws_security_group.hybrid_nlb[0].id]
  enable_cross_zone_load_balancing = true
  tags                             = { Owner = var.owner }
}

resource "aws_lb_target_group" "hybrid" {
  count       = local.hybrid_agentic ? 1 : 0
  name_prefix = "sq-p-"
  port        = 9000
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = local.vpc_id_effective
  health_check {
    protocol = "TCP"
    port     = "9000"
  }
  tags = { Owner = var.owner }
}

resource "aws_lb_listener" "hybrid" {
  count             = local.hybrid_agentic ? 1 : 0
  load_balancer_arn = aws_lb.hybrid[0].arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.nlb.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hybrid[0].arn
  }
}

resource "aws_route53_zone" "hybrid" {
  count = local.hybrid_agentic ? 1 : 0
  name  = local.domain_fqdn
  vpc {
    vpc_id = local.vpc_id_effective
  }
  tags = { Owner = var.owner }
}

resource "aws_route53_record" "hybrid_app" {
  count   = local.hybrid_agentic ? 1 : 0
  zone_id = aws_route53_zone.hybrid[0].zone_id
  name    = local.domain_fqdn
  type    = "A"
  alias {
    name                   = aws_lb.hybrid[0].dns_name
    zone_id                = aws_lb.hybrid[0].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "agents" {
  count   = local.hybrid_agentic ? 1 : 0
  zone_id = aws_route53_zone.hybrid[0].zone_id
  name    = local.agentic_fqdn
  type    = "A"
  ttl     = 30
  records = [aws_instance.agents[0].private_ip]
}

resource "aws_s3_object" "windows_bootstrap" {
  count                  = local.hybrid_agentic ? 1 : 0
  bucket                 = aws_s3_bucket.hybrid["bootstrap"].id
  key                    = "windows.ps1"
  server_side_encryption = "AES256"
  content = replace(replace(templatefile("${path.module}/user_data.ps1", {
    url              = var.zip_download_url
    path             = var.win_sonar_dir
    java_url         = var.win_java_url
    java_filename    = var.win_java_filename
    zip_filename     = var.zip_filename
    install_chromium = var.install_chromium
    jdbc_url         = local.jdbc_url
    db_password      = random_password.db_admin.result
    db_username      = var.db_username
    agentic_setup = templatefile("${path.module}/templates/windows_agentic.ps1.tftpl", {
      bucket     = aws_s3_bucket.hybrid["bootstrap"].id
      jobs       = aws_s3_bucket.hybrid["jobs"].id
      region     = var.aws_region
      host       = local.agentic_fqdn
      access_key = aws_iam_access_key.agentic_storage[0].id
      secret_key = aws_iam_access_key.agentic_storage[0].secret
    })
  }), "<powershell>", ""), "</powershell>", "")
  depends_on = [aws_s3_bucket_public_access_block.hybrid, aws_s3_bucket_policy.hybrid]
}

resource "aws_instance" "agents" {
  count                       = local.hybrid_agentic ? 1 : 0
  ami                         = data.aws_ami.agents[0].id
  instance_type               = var.agentic_instance_type
  subnet_id                   = local.primary_subnet_id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.agents[0].id]
  iam_instance_profile        = aws_iam_instance_profile.hybrid["agents"].name
  user_data_replace_on_change = true
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/agentic_linux.sh.tftpl", {
    bucket   = aws_s3_bucket.hybrid["bootstrap"].id
    region   = var.aws_region
    host     = local.agentic_fqdn
    sq_host  = local.domain_fqdn
    revision = var.agentic_generator_revision
    mcp      = var.mcp_image
    profile = jsonencode({
      edition                   = "none"
      db_mode                   = "external"
      db_host                   = aws_db_instance.postgres.address
      db_port                   = "5432"
      db_name                   = local.rds_database_name
      db_user                   = var.db_username
      db_password               = random_password.db_admin.result
      storage                   = "s3"
      s3_bucket                 = aws_s3_bucket.hybrid["jobs"].id
      s3_region                 = var.aws_region
      s3_access_key             = aws_iam_access_key.agentic_storage[0].id
      s3_secret_key             = aws_iam_access_key.agentic_storage[0].secret
      s3_path_style             = "false"
      tls                       = "on"
      tls_server_name           = local.agentic_fqdn
      sonarqube_external_host   = local.domain_fqdn
      sonarqube_external_port   = "443"
      sonarqube_external_scheme = "https"
      sandbox                   = "runsc"
      llm_domains               = join(",", var.agentic_llm_domains)
      custom_ca_dir             = "./custom-ca"
      project_name              = "sonarqube-agentic"
    })
  }))
  root_block_device {
    volume_size           = var.agentic_root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = {
    Name  = "${var.hostname}-agents"
    Owner = var.owner
  }
  depends_on = [aws_iam_role_policy.hybrid, aws_iam_user_policy.agentic_storage, aws_lb_listener.hybrid, aws_route53_record.hybrid_app]
}

output "agentic_host_id" {
  value       = local.hybrid_agentic ? aws_instance.agents[0].id : null
  description = "Separate Linux agent host for a Windows agentic deployment."
}

output "agentic_jobs_bucket" {
  value       = local.hybrid_agentic ? aws_s3_bucket.hybrid["jobs"].id : null
  description = "Private shared agent storage for Windows and the Linux agent host."
}