resource "null_resource" "enable_cluster_backup" {
  triggers = {
    acm_namespace = var.acm_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Enabling cluster-backup on MultiClusterHub..."
      oc patch multiclusterhub multiclusterhub -n ${var.acm_namespace} \
        --type merge \
        -p '{"spec":{"overrides":{"components":[{"name":"cluster-backup","enabled":true}]}}}'
      echo "cluster-backup enabled. ACM will auto-install OADP operator."
    EOT
  }
}

resource "null_resource" "wait_for_oadp_operator" {
  triggers = {
    namespace = var.oadp_namespace
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Waiting for OADP CRD to be registered..."
      until oc get crd dataprotectionapplications.oadp.openshift.io 2>/dev/null; do
        echo "  OADP CRD not yet available, waiting..."
        sleep 15
      done

      echo "Waiting for OADP operator deployment..."
      until oc get deployment -n ${var.oadp_namespace} -l app.kubernetes.io/name=oadp-operator-controller-manager -o name 2>/dev/null | grep -q deployment; do
        sleep 10
      done
      oc wait --for=condition=Available deployment \
        -l app.kubernetes.io/name=oadp-operator-controller-manager \
        -n ${var.oadp_namespace} --timeout=300s
      echo "OADP operator is ready."
    EOT
  }

  depends_on = [null_resource.enable_cluster_backup]
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
        features:
          dataMover:
            enable: false
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
      oc wait --for=jsonpath='{.status.phase}'=Available backupstoragelocations \
        -n ${var.oadp_namespace} --timeout=180s
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
