resource "kubernetes_namespace" "oadp" {
  metadata {
    name = var.oadp_namespace
  }
}

resource "kubernetes_manifest" "operatorgroup" {
  manifest = {
    apiVersion = "operators.coreos.com/v1"
    kind       = "OperatorGroup"
    metadata = {
      name      = "oadp-operator-group"
      namespace = kubernetes_namespace.oadp.metadata[0].name
    }
    spec = {
      targetNamespaces = [kubernetes_namespace.oadp.metadata[0].name]
    }
  }
}

resource "kubernetes_manifest" "subscription" {
  manifest = {
    apiVersion = "operators.coreos.com/v1alpha1"
    kind       = "Subscription"
    metadata = {
      name      = "redhat-oadp-operator"
      namespace = kubernetes_namespace.oadp.metadata[0].name
    }
    spec = {
      channel             = var.oadp_channel
      installPlanApproval = "Automatic"
      name                = "redhat-oadp-operator"
      source              = "redhat-operators"
      sourceNamespace     = "openshift-marketplace"
    }
  }

  depends_on = [kubernetes_manifest.operatorgroup]
}

resource "null_resource" "wait_for_oadp_operator" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for OADP operator deployment..."
      until oc get deployment -n ${var.oadp_namespace} -l app.kubernetes.io/name=oadp-operator-controller-manager -o name 2>/dev/null | grep -q deployment; do
        sleep 10
      done
      oc wait --for=condition=Available deployment \
        -l app.kubernetes.io/name=oadp-operator-controller-manager \
        -n ${var.oadp_namespace} --timeout=300s
    EOT
  }

  depends_on = [kubernetes_manifest.subscription]
}

resource "kubernetes_manifest" "credentials_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "cloud-credentials"
      namespace = kubernetes_namespace.oadp.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "aws-secrets-manager"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "cloud-credentials"
        creationPolicy = "Owner"
        template = {
          type = "Opaque"
          data = {
            credentials = <<-EOF
              [default]
              role_arn = {{ .role_arn }}
              web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
            EOF
          }
        }
      }
      data = [
        {
          secretKey = "role_arn"
          remoteRef = {
            key      = var.secrets_manager_secret_name
            property = "role_arn"
          }
        }
      ]
    }
  }

  depends_on = [
    aws_secretsmanager_secret_version.oadp_credentials,
    null_resource.wait_for_oadp_operator,
  ]
}

resource "kubernetes_manifest" "dpa" {
  manifest = {
    apiVersion = "oadp.openshift.io/v1alpha1"
    kind       = "DataProtectionApplication"
    metadata = {
      name      = "dpa-acm"
      namespace = kubernetes_namespace.oadp.metadata[0].name
    }
    spec = {
      configuration = {
        velero = {
          defaultPlugins = ["openshift", "aws"]
        }
        nodeAgent = {
          enable = false
        }
      }
      backupImages = false
      features = {
        dataMover = {
          enable = false
        }
      }
      backupLocations = [
        {
          velero = {
            provider = "aws"
            default  = true
            objectStorage = {
              bucket = aws_s3_bucket.acm_backup.id
              prefix = var.s3_bucket_prefix
            }
            config = {
              region           = var.aws_region
              s3ForcePathStyle = "false"
              profile          = "default"
            }
            credential = {
              name = "cloud-credentials"
              key  = "credentials"
            }
          }
        }
      ]
    }
  }

  depends_on = [
    null_resource.wait_for_oadp_operator,
    kubernetes_manifest.credentials_external_secret,
  ]
}

resource "null_resource" "wait_for_bsl" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for BackupStorageLocation to become Available..."
      until oc get backupstoragelocations -n ${var.oadp_namespace} -o name 2>/dev/null | grep -q backupstoragelocation; do
        sleep 10
      done
      oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
        -n ${var.oadp_namespace} --timeout=180s
    EOT
  }

  depends_on = [kubernetes_manifest.dpa]
}

resource "kubernetes_manifest" "backup_schedule" {
  manifest = {
    apiVersion = "cluster.open-cluster-management.io/v1beta1"
    kind       = "BackupSchedule"
    metadata = {
      name      = "schedule-acm"
      namespace = kubernetes_namespace.oadp.metadata[0].name
    }
    spec = {
      veleroSchedule           = var.backup_schedule
      veleroTtl                = var.backup_ttl
      useManagedServiceAccount = true
    }
  }

  depends_on = [null_resource.wait_for_bsl]
}

resource "null_resource" "enable_cluster_backup" {
  count = var.enable_cluster_backup ? 1 : 0

  provisioner "local-exec" {
    command = <<-EOT
      oc patch multiclusterhub multiclusterhub -n ${var.acm_namespace} \
        --type merge \
        -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'
    EOT
  }

  depends_on = [null_resource.wait_for_oadp_operator]
}
