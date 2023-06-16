#!/bin/bash

colored_echo() {
  echo -e "\033[1;32m$1\033[0m"
}

colored_echo "1. bootstrap k8s & crossplane controller"
MYDIR=$(dirname $0)
k3d cluster delete awx-hackathon
k3d cluster create awx-hackathon
k3d kubeconfig get awx-hackathon  > /tmp/awx-hackathon.config
export KUBECONFIG=/tmp/awx-hackathon.config

kubectl create namespace crossplane-system
helm repo add crossplane-stable https://charts.crossplane.io/stable && helm repo update
helm install crossplane \
--namespace crossplane-system \
--create-namespace crossplane-stable/crossplane 
kubectl wait deploy crossplane -n crossplane-system  --for condition=Available=True --timeout=90s

colored_echo "2. add gcp provider"
tee provider.yaml <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-gcp
spec:
  package:  asia.gcr.io/airwallex/provider-gcp:v0.32.6
  packagePullSecrets:
  - name: gcr
  controllerConfigRef:
    name: custom-gcp-config
---
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: custom-gcp-config
spec:
  serviceAccountName: crossplane
  args:
    - --poll=10m
    - -d
    - --enable-management-policies
    - --provider-ttl=600
EOF
kubectl apply -f gcr.yaml --namespace crossplane-system
kubectl apply -f  provider.yaml
kubectl wait  provider provider-gcp  --for condition=Healthy=True --timeout=90s

colored_echo "3. apply provider config"
kubectl create secret generic gcp-secret -n crossplane-system --from-file=creds=./gcp-credentials.json

tee providerconfig.yaml <<EOF
apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: fx-nonprod-716f2723
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-secret
      key: creds
EOF

kubectl apply -f providerconfig.yaml

colored_echo "4. add helm provider"
tee provider-helm.yaml <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-helm
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-helm:v0.13.0
  controllerConfigRef:
    name: helm-config-debug
EOF

tee helm-controller-config-debug.yaml <<EOF
apiVersion: pkg.crossplane.io/v1alpha1
kind: ControllerConfig
metadata:
  name: helm-config-debug
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  args:
  - '--debug'
EOF

kubectl apply -f provider-helm.yaml 
kubectl apply -f helm-controller-config-debug.yaml
kubectl wait  provider.pkg.crossplane.io/provider-helm  --for condition=Healthy=True --timeout=90s

colored_echo "5. add kubernetes provider"
tee provider-kubernetes.yaml <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-kubernetes
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  package: "crossplane/provider-kubernetes:v0.4.1"
EOF
kubectl apply -f provider-kubernetes.yaml
kubectl wait  provider.pkg.crossplane.io/provider-kubernetes --for condition=Healthy=True --timeout=90s
