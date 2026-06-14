# FastAPI GCS Service — WIF Demo

A production-ready FastAPI service that accesses Google Cloud Storage from EKS using Workload Identity Federation (no keys).

## Architecture

```
EKS Pod (IRSA) → Assume Hub Role → GCP WIF → GCS
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/objects?prefix=&max_results=100` | List objects |
| GET | `/objects/{path}` | Download object |
| PUT | `/objects/{path}` | Upload object |
| DELETE | `/objects/{path}` | Delete object |

## Local Development

```bash
# Set environment variables
export HUB_ROLE_ARN="arn:aws:iam::<HUB_ACCOUNT>:role/<ROLE_NAME>"
export WIF_AUDIENCE="//iam.googleapis.com/projects/<NUM>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>"
export GCP_SA_EMAIL="<SA>@<PROJECT>.iam.gserviceaccount.com"
export GCP_PROJECT_ID="<PROJECT>"
export GCS_BUCKET="<BUCKET>"

pip install -r requirements.txt
uvicorn app.main:app --reload --port 8080
```

## Deploy to EKS

```bash
# Build and push
docker build -t <REGISTRY>/gcs-wif-service:latest .
docker push <REGISTRY>/gcs-wif-service:latest

# Deploy (edit k8s.yaml with your values first)
kubectl apply -f k8s.yaml
```

## Required Setup

1. **IRSA**: ServiceAccount annotated with spoke role ARN
2. **Hub Role**: Trust policy allowing the spoke role to assume it
3. **GCP WIF**: Provider registered with hub account ID
4. **GCP SA**: Bound to the hub role's principal with `workloadIdentityUser` + `serviceAccountTokenCreator`
5. **GCP IAM**: SA granted `roles/storage.objectAdmin` on the bucket
