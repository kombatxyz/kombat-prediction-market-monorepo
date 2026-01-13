#!/bin/bash
# Production Deployment Script for PM Backend
# Usage: ./deploy.sh [project-id] [region]

set -e

PROJECT_ID=${1:-"your-gcp-project"}
REGION=${2:-"us-central1"}
SERVICE_NAME="pm-backend"
IMAGE_NAME="gcr.io/${PROJECT_ID}/${SERVICE_NAME}"
GCS_BUCKET="pm-market-images-${PROJECT_ID}"

echo "=================================="
echo "PM Backend Production Deployment"
echo "=================================="
echo "Project: ${PROJECT_ID}"
echo "Region: ${REGION}"
echo "Image: ${IMAGE_NAME}"
echo "GCS Bucket: ${GCS_BUCKET}"
echo ""

# Check gcloud is authenticated
gcloud auth print-identity-token > /dev/null 2>&1 || {
  echo "Not authenticated. Run: gcloud auth login"
  exit 1
}

# Set project
gcloud config set project ${PROJECT_ID}

# Step 1: Create GCS bucket
echo "[1/5] Creating GCS bucket..."
gcloud storage buckets create gs://${GCS_BUCKET} --location=${REGION} --uniform-bucket-level-access 2>/dev/null || echo "Bucket already exists"

# Make bucket public for image access
gcloud storage buckets add-iam-policy-binding gs://${GCS_BUCKET} \
  --member=allUsers \
  --role=roles/storage.objectViewer 2>/dev/null || true

# Step 2: Build and push Docker image
echo "[2/5] Building Docker image..."
gcloud builds submit --tag ${IMAGE_NAME} --quiet

# Step 3: Deploy to Cloud Run
echo "[3/5] Deploying to Cloud Run..."
gcloud run deploy ${SERVICE_NAME} \
  --image ${IMAGE_NAME} \
  --platform managed \
  --region ${REGION} \
  --allow-unauthenticated \
  --memory 512Mi \
  --cpu 1 \
  --min-instances 0 \
  --max-instances 10 \
  --set-env-vars "GCS_BUCKET=${GCS_BUCKET}" \
  --set-env-vars "GCS_PROJECT_ID=${PROJECT_ID}" \
  --set-env-vars "NODE_ENV=production" \
  --quiet

# Step 4: Get service URL
echo "[4/5] Getting service URL..."
SERVICE_URL=$(gcloud run services describe ${SERVICE_NAME} --region ${REGION} --format='value(status.url)')

echo "[5/5] Deployment complete!"
echo ""
echo "=================================="
echo "Deployment Summary"
echo "=================================="
echo "API URL:    ${SERVICE_URL}"
echo "Admin:      ${SERVICE_URL}/admin"
echo "GCS Bucket: gs://${GCS_BUCKET}"
echo ""
echo "Next steps:"
echo "1. Set blockchain env vars:"
echo "   gcloud run services update ${SERVICE_NAME} --region ${REGION} \\"
echo "     --set-env-vars RPC_URL=https://rpc.sepolia.mantle.xyz \\"
echo "     --set-env-vars CONDITIONAL_TOKENS_ADDRESS=0xFdA547973c86fd6F185eF6b50d5B3A6ecCE9FF8b \\"
echo "     --set-env-vars PM_EXCHANGE_ADDRESS=0x4acEaEeA1EbC1C4B86a3Efe4525Cd4F6443E0CCF \\"
echo "     --set-env-vars USDC_ADDRESS=0xDdB5BAFf948169775df9B0cd0d5aA067b8856c70 \\"
echo "     --set-env-vars PM_ROUTER_ADDRESS=0xD2F13Ef8190A5A91B83EC75346940a3C61572C32 \\"
echo "     --set-env-vars PM_ADAPTER_ADDRESS=0x6F3e6F69ca4992B12F3FDAc0d1ec366b57D6De48"
echo ""
echo "2. Add admin private key as secret:"
echo "   echo -n '0xYOUR_KEY' | gcloud secrets create pm-admin-key --data-file=-"
echo "   gcloud run services update ${SERVICE_NAME} --region ${REGION} \\"
echo "     --set-secrets ADMIN_PRIVATE_KEY=pm-admin-key:latest"
echo ""
