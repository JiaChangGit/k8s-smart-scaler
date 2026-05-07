#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# K8S Smart Scaler — 一鍵建立環境腳本
# 用法: bash scripts/setup.sh <your-dockerhub-username>
# ─────────────────────────────────────────────────────────────
set -euo pipefail

DOCKERHUB_USER="${1:?請傳入 Docker Hub 帳號，例如: bash scripts/setup.sh jiachanggit}"
CLUSTER_NAME="smart-scaler"

log() { echo -e "\n\033[1;34m▶ $1\033[0m"; }
ok()  { echo -e "\033[1;32m✅ $1\033[0m"; }
err() { echo -e "\033[1;31m❌ $1\033[0m"; exit 1; }

# ── 前置檢查 ──────────────────────────────────────────────────
log "檢查必要工具..."
for cmd in docker kubectl kind helm; do
    command -v "$cmd" >/dev/null 2>&1 || err "$cmd 未安裝"
    echo "  $cmd: $(command -v $cmd)"
done

# ── 建立 Kind Cluster ─────────────────────────────────────────
log "建立 Kind Cluster: $CLUSTER_NAME"

if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo "  Cluster 已存在，跳過建立"
else
    kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}"
ok "Kind Cluster 就緒"

# ── 建立 Namespaces + RBAC ─────────────────────────────────────
log "套用 Namespaces & RBAC..."
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac/
ok "Namespaces & RBAC 設定完成"

# ── 安裝 Prometheus + Grafana ──────────────────────────────────
log "安裝 kube-prometheus-stack (Helm)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --values k8s/monitoring/prometheus-values.yaml \
    --wait --timeout=8m

ok "Prometheus + Grafana 安裝完成"

# ── 建立 Docker Images ─────────────────────────────────────────
log "建立 Docker Images..."

docker build -t "${DOCKERHUB_USER}/k8s-smart-scaler-demo:latest"       ./demo-app
docker build -t "${DOCKERHUB_USER}/k8s-smart-scaler-controller:latest" ./scaler-controller
docker build -t "${DOCKERHUB_USER}/k8s-smart-scaler-prediction:latest" ./prediction-service

ok "Docker Images 建立完成"

# ── 載入 Images 進 Kind ──────────────────────────────────────
log "將 Images 載入 Kind Cluster（省去 push 步驟）..."

kind load docker-image "${DOCKERHUB_USER}/k8s-smart-scaler-demo:latest"       --name "$CLUSTER_NAME"
kind load docker-image "${DOCKERHUB_USER}/k8s-smart-scaler-controller:latest" --name "$CLUSTER_NAME"
kind load docker-image "${DOCKERHUB_USER}/k8s-smart-scaler-prediction:latest" --name "$CLUSTER_NAME"

ok "Images 載入完成"

# ── 替換 YAML 中的帳號 ────────────────────────────────────────
log "更新 deployment.yaml 中的 Docker Hub 帳號..."

for f in k8s/prediction-service/deployment.yaml \
          k8s/scaler-controller/deployment.yaml \
          k8s/demo-app/deployment.yaml; do
    # 只替換還沒被替換的（idempotent）
    sed -i "s|YOUR_DOCKERHUB_USERNAME|${DOCKERHUB_USER}|g" "$f"
done

# ── 部署應用程式 ──────────────────────────────────────────────
log "部署應用程式..."

kubectl apply -f k8s/demo-app/
kubectl apply -f k8s/prediction-service/
kubectl apply -f k8s/scaler-controller/

log "等待 demo-app 就緒..."
kubectl rollout status deployment/demo-app -n demo --timeout=120s

log "等待 prediction-service 就緒（需要 60s+ 因為 Prophet 初始化）..."
kubectl rollout status deployment/prediction-service -n smart-scaler --timeout=300s

ok "所有服務部署完成！"

# ── 顯示存取方式 ──────────────────────────────────────────────
echo ""
echo "=================================================================="
echo "  🎉 K8S Smart Scaler 已就緒"
echo "=================================================================="
echo ""
echo "  服務存取："
echo "  ┌─ Demo App        http://localhost:30080"
echo "  ├─ Prediction API  kubectl port-forward svc/prediction-service 8000:8000 -n smart-scaler"
echo "  ├─ Prometheus      kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring"
echo "  └─ Grafana         kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring"
echo "                     帳號: admin / 密碼: admin123"
echo ""
echo "  快速壓測："
echo "  bash scripts/load-test.sh"
echo ""
echo "  完整演示："
echo "  bash scripts/demo.sh"
echo "=================================================================="
