provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      "rosa_cluster"  = var.cluster_name
      "managed-by"    = "terraform"
      "component"     = "acm-oadp-backup"
    })
  }
}
