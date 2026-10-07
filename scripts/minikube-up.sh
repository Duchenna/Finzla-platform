#!/usr/bin/env bash
set -euo pipefail

minikube start \
  --cpus=2 \
  --memory=4096 \
  --driver=docker \
  --kubernetes-version=v1.29.3

# Enable the NGINX ingress controller (Minikube addon)
minikube addons enable ingress
minikube addons enable metrics-server

# Point docker CLI at Minikube's daemon so `docker build` lands in the cluster
eval "$(minikube -p minikube docker-env)"

echo "Minikube is up. Ingress IP:"
minikube ip