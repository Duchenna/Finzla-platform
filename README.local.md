# Local Run — Minikube

Mirrors the AWS ECS Fargate solution locally.

## Prereqs
- Docker, Minikube, kubectl, helm

## Start
```bash
./scripts/minikube-up.sh
./scripts/deploy.sh
echo "$(minikube ip)  finzla.local" | sudo tee -a /etc/hosts
```

## Verify
```bash
curl -i http://finzla.local/health
curl -i http://finzla.local/version
```

## Inspect
```bash
kubectl -n finzla get pods,svc,ingress
kubectl -n finzla logs -l app=finzla-app -f
kubectl -n finzla get hpa -w
```

## Simulate failure & rollback
```bash
kubectl -n finzla set image deployment/finzla-app app=finzla-app:bad
kubectl -n finzla rollout undo deployment/finzla-app
```

## Stop
```bash
./scripts/minikube-down.sh
```