locals {
  s3_bucket_name = var.s3_bucket_name != "" ? var.s3_bucket_name : "${var.cluster_name}-acm-backup"
}

resource "aws_s3_bucket" "acm_backup" {
  bucket = local.s3_bucket_name
}

resource "aws_s3_bucket_versioning" "acm_backup" {
  bucket = aws_s3_bucket.acm_backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "acm_backup" {
  bucket = aws_s3_bucket.acm_backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "acm_backup" {
  bucket = aws_s3_bucket.acm_backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "acm_backup" {
  bucket = aws_s3_bucket.acm_backup.id

  rule {
    id     = "cleanup-incomplete-uploads"
    status = "Enabled"

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "transition-old-backups"
    status = "Enabled"

    filter {
      prefix = "${var.s3_bucket_prefix}/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}
