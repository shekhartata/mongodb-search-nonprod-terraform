# Stage 2: MCK Operator + MongoDB EA replica set (plain StatefulSet) + MongoDB Search
# Non-prod: no TLS, no Cloud Manager / Ops Manager. MCK manages mongot only.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# ---------------------------------------------------------------- variables

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name from stage 1"
  type        = string
  default     = "mdb-search-test"
}

variable "mck_version" {
  description = "MongoDB Controllers for Kubernetes Helm chart version (>= 1.9.1)"
  type        = string
  default     = "1.9.1"
}

variable "mongodb_image" {
  description = "MongoDB Enterprise image, 8.3.4 or later"
  type        = string
  default     = "mongodb/mongodb-enterprise-server:8.3-ubi9"
}

variable "rs_members" {
  description = "Replica set members (1 is fine for a smoke test)"
  type        = number
  default     = 3
}

# ---------------------------------------------------------------- providers

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
  load_config_file       = false
  apply_retry_count      = 5
}

locals {
  ns = "mongodb"
}

# ---------------------------------------------------------------- cluster basics

resource "kubectl_manifest" "storage_class" {
  yaml_body = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: auto-ebs-sc
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: ebs.csi.eks.amazonaws.com
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      type: gp3
      encrypted: "true"
  YAML
}

resource "kubectl_manifest" "namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${local.ns}
  YAML
}

resource "helm_release" "mck" {
  name       = "mongodb-kubernetes"
  repository = "oci://quay.io/mongodb/helm-charts"
  chart      = "mongodb-kubernetes"
  version    = var.mck_version
  namespace  = local.ns
  timeout    = 900

  depends_on = [kubectl_manifest.namespace]
}

# ---------------------------------------------------------------- secrets + init script

resource "random_password" "keyfile" {
  length  = 756
  special = false
}

resource "random_password" "admin" {
  length  = 24
  special = false
}

resource "random_password" "sync" {
  length  = 24
  special = false
}

resource "kubectl_manifest" "keyfile" {
  sensitive_fields = ["stringData"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "mdb-keyfile", namespace = local.ns }
    stringData = { keyfile = random_password.keyfile.result }
  })
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "admin_secret" {
  sensitive_fields = ["stringData"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "mdb-admin-user-password", namespace = local.ns }
    stringData = { password = random_password.admin.result }
  })
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "sync_secret" {
  sensitive_fields = ["stringData"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = { name = "mdb-search-sync-source-password", namespace = local.ns }
    stringData = { password = random_password.sync.result }
  })
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "init_script" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata   = { name = "mdb-rs-init", namespace = local.ns }
    data       = { "init.js" = file("${path.module}/init.js") }
  })
  depends_on = [kubectl_manifest.namespace]
}

# ---------------------------------------------------------------- mongod replica set (plain StatefulSet)

resource "kubectl_manifest" "mongod_svc" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: mdb-rs-svc
      namespace: ${local.ns}
    spec:
      clusterIP: None
      publishNotReadyAddresses: true
      selector:
        app: mdb-rs
      ports:
        - name: mongodb
          port: 27017
  YAML
  depends_on = [kubectl_manifest.namespace]
}

# Stable alias that mongod uses for mongot; points at the Search Service the operator creates
resource "kubectl_manifest" "mongot_alias" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Service
    metadata:
      name: mongot
      namespace: ${local.ns}
    spec:
      type: ExternalName
      externalName: mdb-search-0-svc.${local.ns}.svc.cluster.local
  YAML
  depends_on = [kubectl_manifest.namespace]
}

resource "kubectl_manifest" "mongod" {
  yaml_body = <<-YAML
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: mdb-rs
      namespace: ${local.ns}
    spec:
      serviceName: mdb-rs-svc
      replicas: ${var.rs_members}
      podManagementPolicy: Parallel
      selector:
        matchLabels:
          app: mdb-rs
      template:
        metadata:
          labels:
            app: mdb-rs
        spec:
          securityContext:
            runAsUser: 999
            runAsGroup: 999
            fsGroup: 999
          initContainers:
            - name: keyfile
              image: busybox:1.36
              securityContext:
                runAsUser: 0
              command: ["sh", "-c", "cp /src/keyfile /keyfile/keyfile && chown 999:999 /keyfile/keyfile && chmod 400 /keyfile/keyfile"]
              volumeMounts:
                - { name: keyfile-src, mountPath: /src }
                - { name: keyfile, mountPath: /keyfile }
          containers:
            - name: mongod
              image: ${var.mongodb_image}
              command: ["mongod"]
              args:
                - --replSet=rs0
                - --bind_ip_all
                - --keyFile=/keyfile/keyfile
                - --setParameter=mongotHost=mongot.${local.ns}.svc.cluster.local:27028
                - --setParameter=searchIndexManagementHostAndPort=mongot.${local.ns}.svc.cluster.local:27028
                - --setParameter=skipAuthenticationToSearchIndexManagementServer=false
                - --setParameter=useGrpcForSearch=true
                - --setParameter=searchTLSMode=disabled
              env:
                - { name: HOME, value: /tmp }
                - { name: RS_MEMBERS, value: "${var.rs_members}" }
                - name: POD_NAMESPACE
                  valueFrom: { fieldRef: { fieldPath: metadata.namespace } }
                - name: ADMIN_SECRET
                  valueFrom: { secretKeyRef: { name: mdb-admin-user-password, key: password } }
                - name: SYNC_SECRET
                  valueFrom: { secretKeyRef: { name: mdb-search-sync-source-password, key: password } }
              ports:
                - containerPort: 27017
              resources:
                requests: { cpu: 500m, memory: 1Gi }
              volumeMounts:
                - { name: data, mountPath: /data/db }
                - { name: keyfile, mountPath: /keyfile }
                - { name: init, mountPath: /init }
          volumes:
            - { name: keyfile-src, secret: { secretName: mdb-keyfile } }
            - { name: keyfile, emptyDir: {} }
            - { name: init, configMap: { name: mdb-rs-init } }
      volumeClaimTemplates:
        - metadata:
            name: data
          spec:
            accessModes: ["ReadWriteOnce"]
            resources:
              requests:
                storage: 10Gi
  YAML

  depends_on = [
    kubectl_manifest.storage_class,
    kubectl_manifest.mongod_svc,
    kubectl_manifest.mongot_alias,
    kubectl_manifest.keyfile,
    kubectl_manifest.admin_secret,
    kubectl_manifest.sync_secret,
    kubectl_manifest.init_script,
  ]
}

# One-time: rs.initiate() + create mdb-admin and search-sync-source (needs aws CLI + kubectl locally)
resource "terraform_data" "rs_init" {
  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${var.region} --name ${var.cluster_name} >/dev/null
      kubectl -n ${local.ns} rollout status statefulset/mdb-rs --timeout=900s
      kubectl -n ${local.ns} exec mdb-rs-0 -c mongod -- mongosh --quiet --file /init/init.js
    EOT
  }
  depends_on = [kubectl_manifest.mongod]
}

# ---------------------------------------------------------------- MongoDB Search (mongot, MCK-managed)

resource "kubectl_manifest" "search" {
  yaml_body = <<-YAML
    apiVersion: mongodb.com/v1
    kind: MongoDBSearch
    metadata:
      name: mdb
      namespace: ${local.ns}
    spec:
      source:
        username: search-sync-source
        passwordSecretRef:
          name: mdb-search-sync-source-password
          key: password
        external:
          hostAndPorts:
            - mdb-rs-0.mdb-rs-svc.${local.ns}.svc.cluster.local:27017
          keyfileSecretRef:
            name: mdb-keyfile
            key: keyfile
      clusters:
        - replicas: 1
  YAML

  depends_on = [helm_release.mck, terraform_data.rs_init]
}

# ---------------------------------------------------------------- outputs

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "wait_for_search" {
  value = "kubectl -n ${local.ns} wait --for=jsonpath='{.status.phase}'=Running mdbs/mdb --timeout=900s"
}

output "check_search_service" {
  description = "Should list mdb-search-0-svc (the target of the mongot alias)"
  value       = "kubectl -n ${local.ns} get svc | grep search"
}

output "connect" {
  value = "kubectl -n ${local.ns} run mongosh --rm -it --restart=Never --image=mongodb/mongodb-community-server:latest --command -- mongosh 'mongodb://mdb-rs-svc.${local.ns}.svc.cluster.local:27017/?replicaSet=rs0' -u mdb-admin --authenticationDatabase admin"
}
