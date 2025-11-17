########################################
# Terraform + Providers
########################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  # Auth comes from environment variables or GitHub Actions
  region = var.aws_region
}

########################################
# Variables
########################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "healthai"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "db_master_username" {
  type    = string
  default = "healthai_admin"
}

variable "db_master_password" {
  type        = string
  sensitive   = true
  description = "Aurora PostgreSQL master password"
}

variable "eks_cluster_version" {
  type    = string
  default = "1.28"
}

########################################
# Data Sources
########################################

data "aws_availability_zones" "available" {}

data "aws_caller_identity" "current" {}

locals {
  name_prefix = "${var.project_name}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)
}

########################################
# KMS Key (Encryption)
########################################

resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} encryption key"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name = "${local.name_prefix}-kms"
  }
}

########################################
# NETWORKING: VPC, Subnets, Routing
########################################

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# Public Subnets
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                     = "${local.name_prefix}-public-${count.index + 1}"
    "kubernetes.io/role/elb" = 1
  }
}

# Private Subnets
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(aws_vpc.main.cidr_block, 4, count.index + 2)
  availability_zone = local.azs[count.index]

  tags = {
    Name                              = "${local.name_prefix}-private-${count.index + 1}"
    "kubernetes.io/role/internal-elb" = 1
  }
}

# NAT Gateways
resource "aws_eip" "nat" {
  count = 2
  vpc   = true

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index + 1}"
  }
}

resource "aws_nat_gateway" "nat" {
  count         = 2
  subnet_id     = aws_subnet.public[count.index].id
  allocation_id = aws_eip.nat[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index + 1}"
  }
}

# Public Route Table
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private Route Tables
resource "aws_route_table" "private" {
  count = 2
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[count.index].id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt-${count.index + 1}"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

########################################
# Security Groups
########################################

resource "aws_security_group" "eks_nodes" {
  name   = "${local.name_prefix}-eks-nodes-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-eks-nodes-sg" }
}

resource "aws_security_group" "rds" {
  name   = "${local.name_prefix}-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-rds-sg" }
}

########################################
# IAM for EKS Cluster + Node Group
########################################

resource "aws_iam_role" "eks_cluster_role" {
  name = "${local.name_prefix}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_AmazonEKSClusterPolicy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "eks_node_role" {
  name = "${local.name_prefix}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" },
      Action   = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_node_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

########################################
# EKS Cluster + Worker Nodes
########################################

resource "aws_eks_cluster" "this" {
  name     = "${local.name_prefix}-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = var.eks_cluster_version

  vpc_config {
    subnet_ids         = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    security_group_ids = [aws_security_group.eks_nodes.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_AmazonEKSClusterPolicy
  ]
}

resource "aws_eks_node_group" "api_nodes" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${local.name_prefix}-api-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = aws_subnet.private[*].id

  scaling_config {
    desired_size = 2
    max_size     = 5
    min_size     = 1
  }

  instance_types = ["t3.medium"]
  disk_size      = 50

  depends_on = [
    aws_eks_cluster.this,
    aws_iam_role_policy_attachment.eks_node_AmazonEKSWorkerNodePolicy
  ]
}

########################################
# Aurora PostgreSQL
########################################

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "${local.name_prefix}-rds-subnet-group"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_rds_cluster" "main" {
  cluster_identifier      = "${local.name_prefix}-aurora-cluster"
  engine                  = "aurora-postgresql"
  engine_version          = "15.4"
  database_name           = "healthai"
  master_username         = var.db_master_username
  master_password         = var.db_master_password
  db_subnet_group_name    = aws_db_subnet_group.rds_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  storage_encrypted       = true
  kms_key_id              = aws_kms_key.main.arn

  backup_retention_period = 7
  preferred_backup_window = "03:00-04:00"
}

resource "aws_rds_cluster_instance" "writer" {
  identifier         = "${local.name_prefix}-aurora-writer-1"
  cluster_identifier = aws_rds_cluster.main.id
  instance_class     = "db.r6g.large"
  engine             = aws_rds_cluster.main.engine
}

########################################
# S3 Buckets (PHI Ready)
########################################

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  s3_suffix = random_id.suffix.hex
}

# Medical Records bucket
resource "aws_s3_bucket" "medical_records" {
  bucket = "${var.project_name}-medical-records-${local.s3_suffix}"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.main.arn
      }
    }
  }

  versioning {
    enabled = true
  }
}

# ML Model Registry bucket
resource "aws_s3_bucket" "model_registry" {
  bucket = "${var.project_name}-model-registry-${local.s3_suffix}"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.main.arn
      }
    }
  }

  versioning {
    enabled = true
  }
}

# Backups bucket
resource "aws_s3_bucket" "backups" {
  bucket = "${var.project_name}-backups-${local.s3_suffix}"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.main.arn
      }
    }
  }

  versioning {
    enabled = true
  }

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true
    expiration {
      days = 90
    }
  }
}

########################################
# Outputs
########################################

output "current_aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "current_aws_user_arn" {
  value = data.aws_caller_identity.current.arn
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "eks_cluster_name" {
  value = aws_eks_cluster.this.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "aurora_endpoint" {
  value = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  value = aws_rds_cluster.main.reader_endpoint
}

output "medical_records_bucket" {
  value = aws_s3_bucket.medical_records.bucket
}
