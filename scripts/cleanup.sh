#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# K8S Smart Scaler — 環境清理腳本
#
# 用法:
#   bash scripts/cleanup.sh             # 互動模式（逐步確認）
#   bash scripts/cleanup.sh --all       # 全部清除，不詢問
#   bash scripts/cleanup.sh --soft      # 只刪 K8s 資源，保留 cluster 和 image
#
# 清理範圍（預設全部）:
#   [1] K8s 應用資源   (namespace smart-scaler / demo)
#   [2] Helm releases  (prometheus stack)
#   [3] Kind cluster   (整個 cluster 刪除)
#   [4] Docker images  (三個 smart-scaler image)
#   [5] Docker Compose (container + volume)
#   [6] Port-forward   (殺掉背景 kubectl port-forward)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── 顏色輸出 ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${BLUE}${BOLD}▶ $1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}!!!  $1${NC}"; }
info()    { echo -e "${CYAN}   $1${NC}"; }
err()     { echo -e "${RED}❌ $1${NC}"; }

# ── 參數解析 ──────────────────────────────────────────────────────────────────
MODE="interactive"
[[ "${1:-}" == "--all"  ]] && MODE="all"
[[ "${1:-}" == "--soft" ]] && MODE="soft"

CLUSTER_NAME="${CLUSTER_NAME:-smart-scaler}"
DOCKER_USER="${DOCKER_USER:-YOUR_DOCKERHUB_USERNAME}"

# ── 確認函式：互動模式才詢問，--all 模式直接執行 ───────────────────────────────
confirm() {
    local msg="$1"
    if [[ "$MODE" == "all" ]]; then
        echo -e "${YELLOW}  → $msg${NC}"
        return 0
    fi
    echo -en "${YELLOW}  $msg [y/N] ${NC}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 顯示目前狀態
# ─────────────────────────────────────────────────────────────────────────────
show_current_state() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  K8S Smart Scaler — 清理腳本  (mode: ${MODE})${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${CYAN}[ 目前狀態 ]${NC}"

    # Kind clusters
    echo -n "  Kind clusters:  "
    if kind get clusters 2>/dev/null | grep -q "$CLUSTER_NAME"; then
        echo -e "${RED}${CLUSTER_NAME} 運行中${NC}"
    else
        echo -e "${GREEN}無${NC}"
    fi

    # K8s namespaces
    echo -n "  Namespaces:     "
    if kubectl get ns smart-scaler demo 2>/dev/null | grep -q "Active"; then
        echo -e "${RED}smart-scaler / demo 存在${NC}"
    else
        echo -e "${GREEN}無${NC}"
    fi

    # Helm releases
    echo -n "  Helm releases:  "
    if helm list -n monitoring 2>/dev/null | grep -q "prometheus"; then
        echo -e "${RED}prometheus 存在${NC}"
    else
        echo -e "${GREEN}無${NC}"
    fi

    # Docker images
    echo -n "  Docker images:  "
    local img_count
    img_count=$(docker images --format "{{.Repository}}" 2>/dev/null \
        | grep -c "k8s-smart-scaler" || true)
    if [[ "$img_count" -gt 0 ]]; then
        echo -e "${RED}${img_count} 個 smart-scaler image${NC}"
    else
        echo -e "${GREEN}無${NC}"
    fi

    # Docker compose
    echo -n "  Docker Compose: "
    if docker compose ps 2>/dev/null | grep -q "running"; then
        echo -e "${RED}container 運行中${NC}"
    else
        echo -e "${GREEN}未運行${NC}"
    fi

    # Port-forwards
    echo -n "  Port-forwards:  "
    local pf_count
    pf_count=$(pgrep -f "kubectl port-forward" 2>/dev/null | wc -l || echo "0")
    if [[ "$pf_count" -gt 0 ]]; then
        echo -e "${RED}${pf_count} 個 port-forward 背景執行中${NC}"
    else
        echo -e "${GREEN}無${NC}"
    fi

    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: 終止背景 port-forward
# ─────────────────────────────────────────────────────────────────────────────
cleanup_port_forwards() {
    log "Step 1 | 終止背景 port-forward"

    local pids
    pids=$(pgrep -f "kubectl port-forward" 2>/dev/null || true)

    if [[ -z "$pids" ]]; then
        info "沒有背景 port-forward"
        return
    fi

    info "找到以下 port-forward processes:"
    ps -f -p $pids 2>/dev/null | tail -n +2 | awk '{print "    PID " $2 ": " $NF}' || true

    if confirm "終止所有 kubectl port-forward？"; then
        echo "$pids" | xargs kill 2>/dev/null || true
        success "Port-forward 已終止"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: 刪除 K8s 應用資源（namespace）
# ─────────────────────────────────────────────────────────────────────────────
cleanup_k8s_resources() {
    log "Step 2 | 刪除 K8s 應用資源"

    # 確認 kubectl 能連上 cluster
    if ! kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
        warn "無法連上 kind-${CLUSTER_NAME}，跳過 K8s 資源清理"
        return
    fi

    # 刪除 namespace（會連帶刪除裡面所有資源）
    for ns in smart-scaler demo; do
        if kubectl get namespace "$ns" &>/dev/null; then
            if confirm "刪除 namespace: ${ns}（含所有 pods/svc/deployment）？"; then
                kubectl delete namespace "$ns" --timeout=60s
                success "Namespace ${ns} 已刪除"
            fi
        else
            info "Namespace ${ns} 不存在，跳過"
        fi
    done

    # 刪除 RBAC（ClusterRole 是全域的，不隨 namespace 刪除）
    if kubectl get clusterrole smart-scaler-role &>/dev/null; then
        if confirm "刪除 ClusterRole / ClusterRoleBinding？"; then
            kubectl delete clusterrole smart-scaler-role --ignore-not-found
            kubectl delete clusterrolebinding smart-scaler-binding --ignore-not-found
            success "RBAC 資源已刪除"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: 刪除 Helm releases（Prometheus stack）
# ─────────────────────────────────────────────────────────────────────────────
cleanup_helm() {
    log "Step 3 | 刪除 Helm releases"

    if ! command -v helm &>/dev/null; then
        warn "Helm 未安裝，跳過"
        return
    fi

    if helm list -n monitoring 2>/dev/null | grep -q "prometheus"; then
        if confirm "刪除 Helm release: prometheus（Prometheus + Grafana）？"; then
            helm uninstall prometheus -n monitoring --timeout=120s
            success "Helm release prometheus 已刪除"

            # 刪除 monitoring namespace
            if confirm "一併刪除 namespace: monitoring？"; then
                kubectl delete namespace monitoring --timeout=60s --ignore-not-found
                success "Namespace monitoring 已刪除"
            fi
        fi
    else
        info "沒有找到 prometheus Helm release，跳過"
    fi

    # 清除 Helm repo cache（選用）
    if [[ "$MODE" == "all" ]]; then
        helm repo remove prometheus-community 2>/dev/null || true
        info "Helm repo cache 已清除"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: 刪除 Kind Cluster
# ─────────────────────────────────────────────────────────────────────────────
cleanup_kind_cluster() {
    [[ "$MODE" == "soft" ]] && { info "soft 模式：跳過 Kind cluster 刪除"; return; }

    log "Step 4 | 刪除 Kind Cluster"

    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        warn "這會刪除整個 cluster，所有資料都會消失！"
        if confirm "刪除 Kind cluster: ${CLUSTER_NAME}？"; then
            kind delete cluster --name "$CLUSTER_NAME"
            success "Kind cluster ${CLUSTER_NAME} 已刪除"

            # 清理 kubeconfig 裡對應的 context
            kubectl config delete-context "kind-${CLUSTER_NAME}" 2>/dev/null || true
            kubectl config delete-cluster "kind-${CLUSTER_NAME}" 2>/dev/null || true
            kubectl config delete-user "kind-${CLUSTER_NAME}" 2>/dev/null || true
            info "kubeconfig context 已清理"
        fi
    else
        info "Kind cluster ${CLUSTER_NAME} 不存在，跳過"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: 刪除 Docker Images
# ─────────────────────────────────────────────────────────────────────────────
cleanup_docker_images() {
    [[ "$MODE" == "soft" ]] && { info "soft 模式：跳過 Docker image 刪除"; return; }

    log "Step 5 | 刪除 Docker Images"

    # 列出所有 smart-scaler images
    local images
    images=$(docker images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
        | grep "k8s-smart-scaler" || true)

    if [[ -z "$images" ]]; then
        info "沒有找到 smart-scaler Docker images，跳過"
        return
    fi

    echo "  找到以下 images："
    echo "$images" | while read -r img; do
        info "$img"
    done

    if confirm "刪除以上所有 smart-scaler images？"; then
        echo "$images" | xargs docker rmi --force 2>/dev/null || true
        success "Docker images 已刪除"
    fi

    # 清除懸空的 dangling images（build cache 殘留）
    if confirm "一併清除 dangling images（<none>:<none>）？"; then
        docker image prune -f
        success "Dangling images 已清除"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: 停止 Docker Compose
# ─────────────────────────────────────────────────────────────────────────────
cleanup_docker_compose() {
    log "Step 6 | 停止 Docker Compose"

    if ! docker compose ps 2>/dev/null | grep -q "running"; then
        info "Docker Compose 沒有運行中的服務，跳過"
        return
    fi

    if confirm "停止並移除 Docker Compose container？"; then
        docker compose down
        success "Docker Compose containers 已停止"
    fi

    if confirm "一併刪除 Docker Compose volumes（Prometheus/Grafana 資料）？"; then
        docker compose down -v
        success "Docker Compose volumes 已刪除"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# 最終狀態確認
# ─────────────────────────────────────────────────────────────────────────────
show_final_state() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}  清理完成 — 最終狀態確認${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo "  Kind clusters 剩餘："
    kind get clusters 2>/dev/null && true || info "  （無）"

    echo ""
    echo "  Docker images 剩餘（smart-scaler 相關）："
    docker images | grep "k8s-smart-scaler" || info "  （無）"

    echo ""
    echo "  Port-forward 剩餘："
    pgrep -fa "kubectl port-forward" 2>/dev/null || info "  （無）"

    echo ""
    echo -e "${CYAN}  磁碟使用狀況（清理前後對比請自行 df -h）${NC}"
    docker system df 2>/dev/null || true

    echo ""
    echo -e "${GREEN}  如需重新建立環境：bash scripts/setup.sh <dockerhub帳號>${NC}"
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# 主流程
# ─────────────────────────────────────────────────────────────────────────────
main() {
    show_current_state

    if [[ "$MODE" == "interactive" ]]; then
        echo -e "${YELLOW}即將開始清理，每個步驟會個別確認。${NC}"
        echo -e "${YELLOW}按 Ctrl+C 可隨時中止。${NC}"
        echo ""
    fi

    cleanup_port_forwards
    cleanup_k8s_resources
    cleanup_helm
    cleanup_kind_cluster
    cleanup_docker_images
    cleanup_docker_compose

    show_final_state
}

main
