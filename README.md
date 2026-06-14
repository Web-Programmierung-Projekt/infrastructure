# Wohnmobil Infrastructure

Operational tooling for the three deployment environments (`dev`, `test`, `prod`) of the Wohnmobil booking platform.

The runtime topology is a single GCP Compute Engine VM running three Docker Compose stacks side by side, fronted by SSH-only access. See [the architecture deployment diagram](../architecture/docs/diagrams/08_deployment.puml) for the full picture.

## Repository layout

```
infrastructure/
├── docker-compose.dev.yml      Local dev stack (build from source, port 8000/3000)
├── docker-compose.test.yml     Test stack (port 8001/3001)
├── docker-compose.prod.yml     Prod stack (port 8002/3002)
├── docker-compose.vm.yml       Overlay used on the VM to swap `build:` for pulled images
├── bootstrap-vm.sh             One-time VM setup: Docker, Cloud SQL Proxy, ufw, secrets
├── deploy.sh                   Bring an environment up (laptop or VM)
└── secrets/
    ├── .gitignore              Real *.env files never committed
    ├── dev.env.example         Template (DATABASE_URL, JWT_SECRET, ...)
    ├── test.env.example
    └── prod.env.example
```

The compose files reference the application repos by relative path:

```
Web-Programmierung/
├── backend/                    Cloned alongside this repo
├── frontend/                   Cloned alongside this repo
└── infrastructure/             You are here
```

On the VM the compose files use `docker-compose.vm.yml` overlay to pull pre-built images from GHCR instead of building from source, so the application repos do not need to be cloned on the VM.

## GCP one-time provisioning

Done once by an admin via `gcloud` or the Cloud Console.

```bash
PROJECT=wohnmobil-prod
REGION=europe-west3
ZONE=europe-west3-a

gcloud projects create $PROJECT
gcloud config set project $PROJECT
gcloud services enable compute.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com

# Cloud SQL: db-f1-micro, private IP only.
gcloud sql instances create wohnmobil-postgres \
    --database-version POSTGRES_15 \
    --tier db-f1-micro \
    --region $REGION \
    --no-assign-ip \
    --network default \
    --backup-start-time=02:00

for env in dev test prod; do
    gcloud sql databases create wohnmobil_$env --instance wohnmobil-postgres
    gcloud sql users create wohnmobil_${env}_user \
        --instance wohnmobil-postgres \
        --password "$(openssl rand -base64 24)"
done

# VM: e2-medium in europe-west3-a.
gcloud compute instances create wohnmobil-vm \
    --zone $ZONE \
    --machine-type e2-medium \
    --image-family debian-12 --image-project debian-cloud \
    --boot-disk-size 30GB \
    --service-account "wohnmobil-vm-sa@${PROJECT}.iam.gserviceaccount.com" \
    --scopes cloud-platform

# Firewall: only :22 from the team's static IPs (replace with real CIDRs).
gcloud compute firewall-rules delete --quiet default-allow-icmp default-allow-rdp default-allow-ssh default-allow-internal || true
gcloud compute firewall-rules create allow-ssh-from-team \
    --direction INGRESS \
    --allow tcp:22 \
    --source-ranges "1.2.3.4/32,5.6.7.8/32"
```

Store one secret per environment in Secret Manager. The bootstrap script will read these into `secrets/<env>.env` on the VM.

```bash
for env in dev test prod; do
    gcloud secrets create ${env}-env --replication-policy automatic
    # Then add a version each time the secret rotates:
    gcloud secrets versions add ${env}-env --data-file secrets/${env}.env
done
```

## VM bootstrap

```bash
gcloud compute ssh wohnmobil-vm --zone europe-west3-a
git clone https://github.com/Web-Programmierung-Projekt/infrastructure.git
cd infrastructure
sudo GCP_PROJECT_ID=wohnmobil-prod \
     CLOUDSQL_INSTANCE=wohnmobil-prod:europe-west3:wohnmobil-postgres \
     ALLOWED_SSH_CIDRS=1.2.3.4/32,5.6.7.8/32 \
     ./bootstrap-vm.sh
```

The script is idempotent. Re-run it after any of these inputs change.

## Local development

Each contributor runs the dev stack on their own laptop.

```bash
cp secrets/dev.env.example secrets/dev.env
# Edit secrets/dev.env to point at your local Postgres and pick a JWT secret.
./deploy.sh dev
```

Expected after a few seconds:

* `http://localhost:8000/health` → `{"status": "ok", "env": "dev"}`
* `http://localhost:3000` → the Next.js app

To rebuild after backend changes:

```bash
docker compose -f docker-compose.dev.yml up -d --build backend
```

## Deploying to the VM

Connect, fetch the latest images, restart:

```bash
ssh wohnmobil-vm
cd ~/infrastructure
git pull
GHCR_OWNER=web-programmierung-projekt GHCR_TAG=$(git rev-parse --short HEAD) \
    ./deploy.sh test --vm
```

The script pulls `ghcr.io/${GHCR_OWNER}/backend:${GHCR_TAG}` and `…/frontend:${GHCR_TAG}`, brings the compose stack up, and runs `alembic upgrade head` against the corresponding Cloud SQL database.

For prod, replace `test` with `prod`. GitHub Actions automates the test path on every push to `main`; the prod path is gated by manual `workflow_dispatch`.

## Reaching a deployed environment

There is no public ingress. Open an SSH tunnel and visit the corresponding port on `localhost`:

| Env  | Backend  | Frontend |
|------|----------|----------|
| dev  | 8000     | 3000     |
| test | 8001     | 3001     |
| prod | 8002     | 3002     |

```bash
# Tunnel test:
ssh -L 8001:127.0.0.1:8001 -L 3001:127.0.0.1:3001 wohnmobil-vm
# Then in the browser: http://localhost:3001
```

## Rolling back

`docker compose` keeps the previous image around. Pin to the prior commit and redeploy:

```bash
GHCR_TAG=<previous-commit-sha> ./deploy.sh prod --vm
```

For schema rollback, find the prior Alembic revision in [backend/alembic/versions/](../backend/alembic/versions/) and:

```bash
docker compose -f docker-compose.prod.yml exec -T backend alembic downgrade <revision>
```

Database rollbacks are destructive — confirm a Cloud SQL backup exists first via the Cloud Console.

## Cost guardrails

| Resource             | Tier            | Approx €/month |
|----------------------|-----------------|---------------:|
| Compute Engine       | e2-medium       |          25.00 |
| Cloud SQL Postgres   | db-f1-micro     |          10.00 |
| Egress (VM ↔ DB)     | private VPC     |           0.00 |
| Snapshots / backups  | default policy  |          ~1.00 |

Total target: **≤ €40 / month**. Set a Cloud Billing budget alert at €50 to catch surprises.
