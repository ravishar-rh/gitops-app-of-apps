resource "null_resource" "argocd_rbac" {
  provisioner "local-exec" {
    command = <<-EOT
      cat <<'YAML' | oc apply -f -
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRole
      metadata:
        name: argocd-acm-oadp-manager
      rules:
        - apiGroups:
            - oadp.openshift.io
          resources:
            - dataprotectionapplications
            - cloudstorages
          verbs:
            - get
            - list
            - watch
            - create
            - update
            - patch
            - delete
        - apiGroups:
            - cluster.open-cluster-management.io
          resources:
            - backupschedules
            - restores
          verbs:
            - get
            - list
            - watch
            - create
            - update
            - patch
            - delete
        - apiGroups:
            - velero.io
          resources:
            - backups
            - restores
            - schedules
            - backupstoragelocations
          verbs:
            - get
            - list
            - watch
            - create
            - update
            - patch
            - delete
        - apiGroups:
            - external-secrets.io
          resources:
            - externalsecrets
          verbs:
            - get
            - list
            - watch
            - create
            - update
            - patch
            - delete
      ---
      apiVersion: rbac.authorization.k8s.io/v1
      kind: ClusterRoleBinding
      metadata:
        name: argocd-acm-oadp-manager
      roleRef:
        apiGroup: rbac.authorization.k8s.io
        kind: ClusterRole
        name: argocd-acm-oadp-manager
      subjects:
        - kind: ServiceAccount
          name: openshift-gitops-argocd-application-controller
          namespace: openshift-gitops
      YAML
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      oc delete clusterrolebinding argocd-acm-oadp-manager --ignore-not-found
      oc delete clusterrole argocd-acm-oadp-manager --ignore-not-found
    EOT
  }
}

resource "null_resource" "dpa" {
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
    command = "oc delete dataprotectionapplication dpa-acm -n open-cluster-management-backup --ignore-not-found"
  }

  depends_on = [null_resource.argocd_rbac]
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
}

resource "null_resource" "verify_deployment" {
  provisioner "local-exec" {
    command = <<-EOT
      echo "AWS infrastructure and ArgoCD RBAC are ready."
      echo ""
      echo "S3 Bucket:       ${aws_s3_bucket.acm_backup.id}"
      echo "IAM Role ARN:    ${aws_iam_role.oadp.arn}"
      echo "Secrets Manager: ${var.secrets_manager_secret_name}"
      echo ""
      echo "ArgoCD will deploy the OADP operator and configure backups."
      echo "Verify with:"
      echo "  oc get dpa -n ${var.oadp_namespace}"
      echo "  oc get backupstoragelocations -n ${var.oadp_namespace}"
      echo "  oc get backupschedule -n ${var.oadp_namespace}"
    EOT
  }

  depends_on = [
    aws_s3_bucket.acm_backup,
    aws_iam_role_policy_attachment.oadp,
    aws_secretsmanager_secret_version.oadp_credentials,
    null_resource.argocd_rbac,
    null_resource.dpa,
  ]
}
