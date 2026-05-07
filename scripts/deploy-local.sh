#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# scripts/deploy-local.sh
#
# 取代 CI/CD 的 deploy job，在本機對 kind cluster 執行部署。
# CI/CD 負責 test + build + push image，
# 部署這步在本機手動跑這支腳本。
#
# 用法：bash scripts/deploy-local.sh [image-tag]
#   image-tag 選填，預設用 latest
#   例如: bash scripts/deploy-local.sh sha-a1b2c3d
# ─────────────────────────────────────────────────────────────
set -euo pipefail

DOCKERHUB_USER="jiachanggit"          # ← 你的 Docker Hub 帳號
CLUSTER_NAME="smart-scaler"
IMAGE_TAG="${1:-latest}"

log() { echo -e "\n\033[1;34m▶ $1\033[0m"; }
ok()  { echo -e "\033[1;32m✅ $1\033[0m"; }
err() { echo -e "\033[1;31m❌ $1\033[0m"; exit 1; }

# ── 確認 cluster 有在跑 ──────────────────────────────────────
log "確認 Kind Cluster 狀態..."
kubectl cluster-info --context "kind-${CLUSTER_NAME}" \
  || err "Kind cluster ${CLUSTER_NAME} 不在線，請先執行 bash scripts/setup.sh"
ok "Cluster 正常"

# ── 如果 tag 不是 latest，從 Docker Hub pull 最新 image ──────
if [[ "$IMAGE_TAG" != "latest" ]]; then
  log "從 Docker Hub 拉取 image tag: ${IMAGE_TAG}..."

  for img in prediction controller demo; do
    case $img in
      prediction) name="k8s-smart-scaler-prediction" ;;
      controller) name="k8s-smart-scaler-controller" ;;
      demo)       name="k8s-smart-scaler-demo" ;;
    esac

    docker pull "${DOCKERHUB_USER}/${name}:${IMAGE_TAG}"
    kind load docker-image "${DOCKERHUB_USER}/${name}:${IMAGE_TAG}" \
      --name "$CLUSTER_NAME"
  done

  ok "Images 載入 kind 完成"
fi

# ── 更新 YAML 中的帳號和 tag ─────────────────────────────────
log "更新 deployment.yaml..."

# 先確保帳號已替換
for f in k8s/prediction-service/deployment.yaml \
          k8s/scaler-controller/deployment.yaml \
          k8s/demo-app/deployment.yaml; do
  sed -i "s|YOUR_DOCKERHUB_USERNAME|${DOCKERHUB_USER}|g" "$f"
done

# 如果指定了特定 tag，更新 image tag
if [[ "$IMAGE_TAG" != "latest" ]]; then
  for f in k8s/prediction-service/deployment.yaml \
            k8s/scaler-controller/deployment.yaml \
            k8s/demo-app/deployment.yaml; do
    sed -i "s|:latest|:${IMAGE_TAG}|g" "$f"
  done
fi

# ── 套用 manifests ────────────────────────────────────────────
log "套用 K8s manifests..."

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac/
kubectl apply -f k8s/prediction-service/
kubectl apply -f k8s/scaler-controller/
kubectl apply -f k8s/demo-app/

# ── 等待部署完成 ──────────────────────────────────────────────
log "等待 demo-app 就緒..."
kubectl rollout status deployment/demo-app \
  -n demo --timeout=120s

log "等待 prediction-service 就緒..."
kubectl rollout status deployment/prediction-service \
  -n smart-scaler --timeout=180s

log "等待 scaler-controller 就緒..."
kubectl rollout status deployment/scaler-controller \
  -n smart-scaler --timeout=60s

# ── 部署結果 ─────────────────────────────────────────────────
ok "部署完成！"
echo ""
echo "=== Pod 狀態 ==="
kubectl get pods -n smart-scaler
kubectl get pods -n demo
echo ""
echo "=== 服務 ==="
kubectl get svc -n smart-scaler
kubectl get svc -n demo
echo ""
echo "  存取方式："
echo "  Demo App   → http://localhost:30080"
echo "  Prediction → kubectl port-forward svc/prediction-service 8000:8000 -n smart-scaler"
