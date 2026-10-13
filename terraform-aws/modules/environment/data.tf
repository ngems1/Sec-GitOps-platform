# ---------------------------------------------------------------------------
# KMS: one customer-managed key per environment (database, its secret)
# ---------------------------------------------------------------------------
resource "aws_kms_key" "env" {
  description             = "${var.name_prefix} data encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7
}

resource "aws_kms_alias" "env" {
  name          = "alias/${var.name_prefix}"
  target_key_id = aws_kms_key.env.key_id
}

# ---------------------------------------------------------------------------
# RDS MySQL: products (catalog) and orders (checkout, order-status Lambda)
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "mysql" {
  name       = "${var.name_prefix}-mysql"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "mysql" {
  name        = "${var.name_prefix}-mysql"
  description = "MySQL for ${var.env}, reachable only from inside the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "MySQL from pods and the order-status Lambda"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

resource "aws_db_instance" "mysql" {
  identifier     = "${var.name_prefix}-mysql"
  engine         = "mysql"
  engine_version = "8.4" # LTS line; 8.0 left standard support in 2026
  instance_class = var.db_instance_class
  db_name        = "boutique"
  username       = "boutique_admin"

  # RDS creates the password, stores it in Secrets Manager and rotates it.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.env.key_id

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.env.arn

  multi_az               = var.db_multi_az
  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.mysql.id]
  publicly_accessible    = false

  backup_retention_period    = var.db_backup_retention_days
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Week 3 lab settings so `terraform destroy` works in one go.
  deletion_protection = false
  skip_final_snapshot = true
}

# ---------------------------------------------------------------------------
# ElastiCache Redis: carts (cartservice) and the catalog cache, TLS + auth token
# ---------------------------------------------------------------------------
resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name_prefix}-redis"
  subnet_ids = var.private_subnet_ids
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis for ${var.env}, reachable only from inside the VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "Redis from pods"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }
}

# One auth token per environment: a dev pod holds the dev token only, so it can no
# longer use prod Redis even though the network lets it connect (closes the
# "prod Redis reachable from dev" gap). Letters and digits only, as ElastiCache
# requires; it lives in the (encrypted) Terraform state and reaches the pods as a
# Kubernetes Secret created by the deploy workflow.
resource "random_password" "redis_auth" {
  length  = 32
  special = false
}

# A replication group (one node) instead of aws_elasticache_cluster: only replication
# groups support encryption in transit and an auth token for Redis.
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "${var.name_prefix}-redis"
  description                = "Carts and catalog cache for ${var.env} (TLS + auth token)"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  parameter_group_name       = "default.redis7"
  port                       = 6379
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  snapshot_retention_limit   = 1
  apply_immediately          = true

  transit_encryption_enabled = true
  transit_encryption_mode    = "required"
  auth_token                 = random_password.redis_auth.result
  at_rest_encryption_enabled = true
  kms_key_id                 = aws_kms_key.env.arn
}

# ---------------------------------------------------------------------------
# DynamoDB: inventory (stock + reservations) and the notification log
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "inventory" {
  name         = "${var.name_prefix}-inventory"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk" # PRODUCT#<id> or RESERVATION#<orderId>

  attribute {
    name = "pk"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "notifications" {
  name         = "${var.name_prefix}-notifications"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "notificationId"

  attribute {
    name = "notificationId"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}
