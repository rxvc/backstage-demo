# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the **BackStack Demo** — a workshop/demo environment integrating four Kubernetes-native tools into a unified platform:
- **Backstage** — Developer portal (frontend + backend, Yarn workspace)
- **Crossplane** — Infrastructure-as-code via Kubernetes custom resources
- **ArgoCD** — GitOps continuous delivery
- **Kyverno** — Kubernetes policy engine

The stack runs on a **KinD (Kubernetes in Docker)** cluster and can be deployed via GitHub Codespaces (devcontainer) or manually.

## Repository Structure

- `backstage/source/` — Backstage app (Yarn 4 monorepo with `packages/app` frontend and `packages/backend`)
- `backstage/values-templated.yaml` — Helm values for Codespaces-based deployment (uses `envsubst`)
- `crossplane/` — Ordered deployment: `01-functions/` → `02-providers/` → `03-provider-configs/` → `04-xrds/` → `05-compositions/` → `06-examples/`
- `argo/` — ArgoCD ApplicationSet template (`app-set-template.yaml` uses `envsubst` with `GITHUB_OWNER`/`GITHUB_REPO`)
- `envoy-gateway/` — Envoy Gateway configuration (Gateway, EnvoyProxy, TLS Certificate)
- `kyverno/` — Cluster policies (nginx blocking, autoscaling requirements, unique HTTPRoute hosts)
- `kind/config.yaml` — KinD cluster config (single control-plane node, ports 80/443 mapped)
- `.devcontainer/` — Codespaces setup; `post-create.sh` orchestrates full cluster bootstrap

## Backstage Development

All Backstage commands run from `backstage/source/`:

```bash
cd backstage/source
yarn install
yarn start            # Start dev server (frontend :3000, backend :7007)
yarn build:backend    # Build backend only
yarn build:all        # Build all packages
yarn test             # Run tests
yarn test:all         # Run tests with coverage
yarn test:e2e         # Playwright end-to-end tests
yarn lint             # Lint changed files (since origin/master)
yarn lint:all         # Lint all files
yarn tsc              # TypeScript check
yarn prettier:check   # Check formatting
yarn new              # Scaffold new plugin/package
```

### Required Environment Variables

```bash
export GITHUB_TOKEN="<pat>"
export GITHUB_CLIENT_ID="<oauth-client-id>"
export GITHUB_CLIENT_SECRET="<oauth-client-secret>"
export GITHUB_OWNER="<github-org-or-user>"
export GITHUB_REPO="<repo-name>"
export KUBERNETES_URL="<k8s-api-url>"
export KUBERNETES_SERVICE_ACCOUNT_TOKEN="<sa-token>"
export ARGOCD_ADMIN_PASSWORD="<argocd-password>"
export NODE_OPTIONS="--max_old_space_size=8192 --no-node-snapshot"
export NODE_TLS_REJECT_UNAUTHORIZED=0
```

### Config Layering

- `app-config.yaml` — Base config (default local dev)
- `app-config.local.yaml` — Local overrides with BackStack integrations (Crossplane, Kyverno, Kubernetes Ingestor, ArgoCD, AI rules)
- `app-config.production.yaml` — Production/container deployment config

### Key Backend Plugins (TerasTky/Community)

The backend (`packages/backend`) includes several non-standard plugins:
- `@terasky/backstage-plugin-kubernetes-ingestor` — Auto-ingests K8s workloads and Crossplane XRDs into the catalog
- `@terasky/backstage-plugin-crossplane-resources-backend` — Crossplane resource management
- `@terasky/backstage-plugin-kyverno-policy-reports-backend` — Kyverno policy report integration
- `@terasky/backstage-plugin-scaffolder-backend-module-terasky-utils` — Custom scaffolder actions
- `@backstage-community/plugin-redhat-argocd-backend` — ArgoCD backend integration
- `@backstage/plugin-mcp-actions-backend` — MCP (Model Context Protocol) actions

### Key Frontend Plugins

- `@terasky/backstage-plugin-crossplane-resources-frontend` — Crossplane UI
- `@terasky/backstage-plugin-kyverno-policy-reports` — Kyverno reports UI
- `@terasky/backstage-plugin-entity-scaffolder-content` — Entity scaffolder
- `@terasky/backstage-plugin-gitops-manifest-updater` — GitOps manifest updates
- `@backstage-community/plugin-redhat-argocd` — ArgoCD UI

## Crossplane Resources

XRDs and Compositions are organized by app type (`basic-app`, `web-app`). Each composition type has multiple function variants (go-templating, KCL, patch-transform, pythonic). Deploy in numbered order — functions and providers must be ready before XRDs and compositions.

## ArgoCD GitOps Pattern

The ApplicationSet in `argo/app-set-template.yaml` watches the Git repo for files matching `demo-cluster/*/*/*.yaml` and auto-creates ArgoCD Applications. The path structure encodes: `demo-cluster/<namespace>/<kind>/<name>.yaml`.

## Cluster Setup

For manual setup, follow `MANUAL_SETUP.md`. For Codespaces, the devcontainer's `post-create.sh` handles everything (KinD cluster, cert-manager, Envoy Gateway, Kyverno, Crossplane, ArgoCD, RBAC, metrics-server).
