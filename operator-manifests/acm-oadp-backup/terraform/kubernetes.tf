resource "kubernetes_namespace" "oadp" {
  metadata {
    name = var.oadp_namespace
  }
}

resource "null_resource" "operatorgroup" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
      apiVersion: operators.coreos.com/v1
      kind: OperatorGroup
      metadata:
        name: oadp-operator-group
        namespace: ${var.oadp_namespace}
      spec:
        targetNamespaces:
          - ${var.oadp_namespace}
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oc delete operatorgroup oadp-operator-group -n open-cluster-management-backup --ignore-not-found"
  }

  depends_on = [kubernetes_namespace.oadp]
}

resource "null_resource" "subscription" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
      apiVersion: operators.coreos.com/v1alpha1
      kind: Subscription
      metadata:
        name: redhat-oadp-operator
        namespace: ${var.oadp_namespace}
      spec:
        channel: ${var.oadp_channel}
        installPlanApproval: Automatic
        name: redhat-oadp-operator
        source: redhat-operators
        sourceNamespace: openshift-marketplace
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "oc delete subscription redhat-oadp-operator -n open-cluster-management-backup --ignore-not-found"
  }

  depends_on = [null_resource.operatorgroup]
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

  depends_on = [null_resource.subscription]
}

resource "null_resource" "credentials_external_secret" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
      apiVersion: external-secrets.io/v1beta1
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
    command = "oc delete externalsecret cloud-credentials -n open-cluster-management-backup --ignore-not-found"
  }

  depends_on = [
    aws_secretsmanager_secret_version.oadp_credentials,
    null_resource.wait_for_oadp_operator,
  ]
}

resource "null_resource" "dpa" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
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
    command = "oc delete dataprotectionapplication dpa-acm -n open-cluster-management-backup --ignore-not-found"
  }

  depends_on = [
    null_resource.wait_for_oadp_operator,
    null_resource.credentials_external_secret,
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

  depends_on = [null_resource.dpa]
}

resource "null_resource" "backup_schedule" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
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
    command = "oc delete backupschedule schedule-acm -n open-cluster-management-backup --ignore-not-found"
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
