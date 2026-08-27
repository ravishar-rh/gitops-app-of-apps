resource "null_resource" "check_oc_login" {
  provisioner "local-exec" {
    command = <<-EOT
      if ! oc whoami &>/dev/null; then
        echo ""
        echo "ERROR: Not logged in to an OpenShift cluster."
        echo "Run 'oc login' before running terraform apply."
        echo ""
        exit 1
      fi
      echo "Logged in as: $(oc whoami)"
      echo "Cluster: $(oc whoami --show-server)"
    EOT
  }
}

resource "null_resource" "wait_for_oadp_operator" {
  triggers = {
    namespace = var.oadp_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Checking that OADP operator is installed..."
      echo "(OADP is managed by ArgoCD via operator-manifests/oadp-operator/)"
      echo ""

      if ! oc get crd dataprotectionapplications.oadp.openshift.io &>/dev/null; then
        echo "ERROR: OADP CRD not found."
        echo ""
        echo "Ensure the following are synced in ArgoCD before running terraform apply:"
        echo "  1. acm-hub app (MultiClusterHub with cluster-backup enabled)"
        echo "  2. oadp-operator app (OADP Subscription)"
        echo "  3. Approve the OADP InstallPlan:"
        echo "     oc get installplan -n ${var.oadp_namespace}"
        echo "     oc patch installplan <name> -n ${var.oadp_namespace} --type merge -p '{\"spec\":{\"approved\":true}}'"
        echo ""
        exit 1
      fi

      echo "Waiting for OADP operator deployment to be ready..."
      oc wait --for=condition=Available deployment \
        -l app.kubernetes.io/name=oadp-operator-controller-manager \
        -n ${var.oadp_namespace} --timeout=300s
      echo "OADP operator is ready."
    EOT
  }

  depends_on = [null_resource.check_oc_login]
}

resource "null_resource" "credentials_external_secret" {
  triggers = {
    namespace   = var.oadp_namespace
    secret_name = var.secrets_manager_secret_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
      apiVersion: external-secrets.io/v1
      kind: ExternalSecret
      metadata:
        name: cloud-credentials
        namespace: ${var.oadp_namespace}
      spec:
        refreshInterval: 1h
        secretStoreRef:
          name: aws-secrets-manager
          kind: ClusterSecretStore
        target:
          name: cloud-credentials
          creationPolicy: Owner
          template:
            type: Opaque
            data:
              credentials: |
                [default]
                role_arn = {{ .role_arn }}
                web_identity_token_file = /var/run/secrets/openshift/serviceaccount/token
        data:
          - secretKey: role_arn
            remoteRef:
              key: ${var.secrets_manager_secret_name}
              property: role_arn
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oc delete externalsecret cloud-credentials -n ${self.triggers.namespace} --ignore-not-found"
  }

  depends_on = [
    aws_secretsmanager_secret_version.oadp_credentials,
    null_resource.wait_for_oadp_operator,
  ]
}

resource "null_resource" "dpa" {
  triggers = {
    namespace = var.oadp_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<YAML | oc apply -f -
      apiVersion: oadp.openshift.io/v1alpha1
      kind: DataProtectionApplication
      metadata:
        name: dpa-acm
        namespace: ${var.oadp_namespace}
      spec:
        configuration:
          velero:
            defaultPlugins:
              - openshift
              - aws
          nodeAgent:
            enable: false
            uploaderType: kopia
        backupImages: false
        backupLocations:
          - velero:
              provider: aws
              default: true
              objectStorage:
                bucket: ${aws_s3_bucket.acm_backup.id}
                prefix: ${var.s3_bucket_prefix}
              config:
                region: ${var.aws_region}
                s3ForcePathStyle: "false"
                profile: default
              credential:
                name: cloud-credentials
                key: credentials
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oc delete dataprotectionapplication dpa-acm -n ${self.triggers.namespace} --ignore-not-found"
  }

  depends_on = [null_resource.credentials_external_secret]
}

resource "null_resource" "wait_for_bsl" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for BackupStorageLocation to become Available..."
      until oc get backupstoragelocations -n ${var.oadp_namespace} -o name 2>/dev/null | grep -q backupstoragelocation; do
        sleep 10
      done
      BSL_NAME=$(oc get backupstoragelocations -n ${var.oadp_namespace} -o jsonpath='{.items[0].metadata.name}')
      oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocation/$BSL_NAME \
        -n ${var.oadp_namespace} --timeout=300s
    EOT
  }

  depends_on = [null_resource.dpa]
}

resource "null_resource" "backup_schedule" {
  triggers = {
    namespace = var.oadp_namespace
    schedule  = var.backup_schedule
    ttl       = var.backup_ttl
  }

  provisioner "local-exec" {
    command = <<-EOT
      cat <<YAML | oc apply -f -
      apiVersion: cluster.open-cluster-management.io/v1beta1
      kind: BackupSchedule
      metadata:
        name: schedule-acm
        namespace: ${var.oadp_namespace}
      spec:
        veleroSchedule: "${var.backup_schedule}"
        veleroTtl: ${var.backup_ttl}
        useManagedServiceAccount: true
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oc delete backupschedule schedule-acm -n ${self.triggers.namespace} --ignore-not-found"
  }

  depends_on = [null_resource.wait_for_bsl]
}

resource "null_resource" "verify_deployment" {
  provisioner "local-exec" {
    command = <<-EOT
      echo ""
      echo "============================================"
      echo "  ACM OADP Backup Setup Complete"
      echo "============================================"
      echo ""
      echo "S3 Bucket:       ${aws_s3_bucket.acm_backup.id}"
      echo "IAM Role ARN:    ${aws_iam_role.oadp.arn}"
      echo "Secrets Manager: ${var.secrets_manager_secret_name}"
      echo ""
      echo "Verify with:"
      echo "  oc get dpa -n ${var.oadp_namespace}"
      echo "  oc get backupstoragelocations -n ${var.oadp_namespace}"
      echo "  oc get backupschedule -n ${var.oadp_namespace}"
      echo "  oc get backups -n ${var.oadp_namespace}"
    EOT
  }

  depends_on = [
    aws_s3_bucket.acm_backup,
    aws_iam_role_policy_attachment.oadp,
    aws_secretsmanager_secret_version.oadp_credentials,
    null_resource.dpa,
    null_resource.backup_schedule,
  ]
}
