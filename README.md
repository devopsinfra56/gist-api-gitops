# gist-api-gitops

This repository contains the GitOps configuration for the gist-api application.

It serves as the deployment source of truth for Kubernetes environments managed by ArgoCD. Application images are built and published through the gist-api CI/CD pipeline, while deployment configuration is managed through Helm charts and ArgoCD applications stored in this repository.

## Technologies

- Kubernetes
- Helm
- ArgoCD
- GitOps
- Docker Hub

## Environments

- Development
- Staging
- Production

## Deployment Flow

Developer → GitHub Actions → Docker Hub → GitOps Repository → ArgoCD → Kubernetes Cluster
