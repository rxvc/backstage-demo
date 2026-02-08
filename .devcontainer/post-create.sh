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

echo "Detect environment..."
if [ "$CODESPACES" = "true" ]; then
  echo "Environment: GitHub Codespaces"
  GATEWAY_HOST="${CODESPACE_NAME}-443.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN}"
else
  echo "Environment: Local Dev Container"
  GATEWAY_HOST="localhost"
fi

echo "Create Cluster Issuer..."
kubectl apply -f cert-manager/ca-issuer.yaml

echo "Install Envoy Gateway..."
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.3.0 \
  -n envoy-gateway-system --create-namespace --wait
kubectl apply -f envoy-gateway/gateway.yaml

echo "Create Gateway TLS Certificate..."
kubectl apply -f- <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-tls
  namespace: envoy-gateway-system
spec:
  secretName: gateway-tls
  issuerRef:
    name: my-ca-issuer
    kind: ClusterIssuer
  dnsNames:
  - localhost
  - "*.localhost"
  - "${GATEWAY_HOST}"
EOF

kubectl -n envoy-gateway-system wait --for=condition=Accepted gateway/backstack-gateway --timeout=5m

echo "Patch Envoy Gateway NodePorts for KinD..."
until kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=backstack-gateway -o jsonpath='{.items[0].spec.ports}' 2>/dev/null | grep -q "443"; do
  sleep 2
done
EG_SVC=$(kubectl get svc -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=backstack-gateway -o jsonpath='{.items[0].metadata.name}')
kubectl -n envoy-gateway-system patch svc "$EG_SVC" --type='json' -p='[
  {"op":"replace","path":"/spec/ports/0/nodePort","value":80},
  {"op":"replace","path":"/spec/ports/1/nodePort","value":443}
]'

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

echo "Install Metrics Server..."
kubectl apply -k metrics-server/

echo "Configure ArgoCD Routing..."
ARGOCD_URL="https://${GATEWAY_HOST}/argocd"

sed "s|REPLACE_ME|${GATEWAY_HOST}|g" argo/httproute-template.yaml > argo/httproute.yaml
kubectl apply -f argo/httproute.yaml
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge \
  -p '{"data":{"server.rootpath":"/argocd","server.basehref":"/argocd","server.insecure":"true"}}'
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
