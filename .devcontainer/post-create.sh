#!/bin/bash
set -e

echo "Setting up Backstack Demo environment..."
if kind get clusters | grep -qx backstack-demo; then
  echo "Kind cluster backstack-demo already exists. Skipping create."
else
  kind create cluster --name backstack-demo --config kind/config.yaml
fi

echo "Install Cert Manager..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.yaml
kubectl -n cert-manager rollout status deploy/cert-manager --timeout=10m
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=10m
kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=10m

echo "Install Ingress NGINX..."
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=10m

echo "Install Kyverno..."
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno -n kyverno --create-namespace --wait --version 3.7.0

echo "Install Crossplane..."
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm repo update
helm install crossplane --namespace crossplane-system --create-namespace crossplane-stable/crossplane --wait

echo "Install ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd --version 9.4.0 --namespace argocd --create-namespace --wait

echo "Create Backstage RBAC..."
kubectl apply -f- <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: backstage-system
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backstage-user
  namespace: backstage-system
---
apiVersion: v1
kind: Secret
metadata:
  name: backstage-token
  namespace: backstage-system
  annotations:
    kubernetes.io/service-account.name: backstage-user
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backstage-kubernetes-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: backstage-user
  namespace: backstage-system
EOF

echo "Configure Crossplane..."
kubectl apply -f- <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: allow-all-resources-crossplane
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: crossplane
  namespace: crossplane-system
EOF
kubectl apply -f crossplane/01-functions
kubectl apply -f crossplane/02-providers
kubectl wait --for condition=Healthy=true providers.pkg.crossplane.io crossplane-contrib-provider-kubernetes --timeout 10m
kubectl apply -f crossplane/03-provider-configs
kubectl apply -f crossplane/04-xrds --recursive
kubectl apply -f crossplane/05-compositions --recursive
kubectl apply -f crossplane/06-examples --recursive

echo "Configure Kyverno..."
kubectl apply -f kyverno/

echo "Create Cluster Issuer..."
kubectl apply -f cert-manager/ca-issuer.yaml

echo "Install Metrics Server..."
kubectl apply -k metrics-server/

echo "Configure ArgoCD Ingress..."
if [ "$CODESPACES" = "true" ]; then 
  echo "Environment: GitHub Codespaces"
  ARGOCD_HOST="${CODESPACE_NAME}-443.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
  ARGOCD_URL="https://${ARGOCD_HOST}/argocd"
else 
  echo "Environment: Local Dev Container"
  ARGOCD_HOST="localhost"
  ARGOCD_URL="https://localhost/argocd"
fi

sed "s|REPLACE_ME|${ARGOCD_HOST}|g" argo/ingress-template.yaml > argo/ingress.yaml 
kubectl apply -f argo/ingress.yaml
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.rootpath":"/argocd","server.basehref":"/argocd"}}'
kubectl -n argocd patch cm argocd-cm --type merge \
  -p "{\"data\":{\"url\":\"${ARGOCD_URL}\"}}"
kubectl -n argocd rollout restart deploy/argocd-server

echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Set up your environment variables (GITHUB_TOKEN, GITHUB_CLIENT_ID, etc.)"
echo "  2. Render and Apply ArgoCD AppSet"
echo "  3. Render Backstage values file"
echo "  4. Deploy Backstage"
echo ""
