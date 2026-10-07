#!/usr/bin/env bash
set -euo pipefail

NS=finzla

# Point docker at Minikube's daemon so the image is visible in-cluster
eval "$(minikube -p minikube docker-env)"

echo "==> Building image finzla-app:local"
docker build -t finzla-app:local ./app

echo "==> Applying manifests"
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/secret.yaml
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/hpa.yaml

echo "==> Waiting for rollout"
kubectl -n $NS rollout status deployment/finzla-app --timeout=120s

echo "==> Pods"
kubectl -n $NS get pods -o wide

echo "==> Services"
kubectl -n $NS get svc

echo "==> Ingress"
kubectl -n $NS get ingress

echo
echo "Add this to /etc/hosts (once):"
echo "  $(minikube ip)  finzla.local"
echo
echo "Then:"
echo "  curl -i http://finzla.local/health"
echo "  curl -i http://finzla.local/version"