data "aws_caller_identity" "current" {}

locals {
  aws_account_id = data.aws_caller_identity.current.account_id
  role_name      = "${var.cluster_name}-acm-backup-oadp"
}

data "aws_iam_policy_document" "oadp_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.aws_account_id}:oidc-provider/${var.oidc_endpoint}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.oidc_endpoint}:sub"
      values = [
        "system:serviceaccount:${var.oadp_namespace}:openshift-adp-controller-manager",
        "system:serviceaccount:${var.oadp_namespace}:velero",
      ]
    }
  }
}

data "aws_iam_policy_document" "oadp_permissions" {
  statement {
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:PutBucketTagging",
      "s3:GetBucketTagging",
      "s3:PutEncryptionConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:PutLifecycleConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucketMultipartUploads",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = [
      aws_s3_bucket.acm_backup.arn,
      "${aws_s3_bucket.acm_backup.arn}/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeSnapshots",
      "ec2:DescribeVolumes",
      "ec2:DescribeVolumeAttribute",
      "ec2:DescribeVolumesModifications",
      "ec2:DescribeVolumeStatus",
      "ec2:CreateTags",
      "ec2:CreateVolume",
      "ec2:CreateSnapshot",
      "ec2:DeleteSnapshot",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "oadp" {
  name   = "${local.role_name}-policy"
  policy = data.aws_iam_policy_document.oadp_permissions.json
}

resource "aws_iam_role" "oadp" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.oadp_trust.json

  tags = {
    rosa_cluster_id = var.cluster_name
  }
}

resource "aws_iam_role_policy_attachment" "oadp" {
  role       = aws_iam_role.oadp.name
  policy_arn = aws_iam_policy.oadp.arn
}
