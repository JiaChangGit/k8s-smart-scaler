#!/usr/bin/env bash
# 演示腳本：完整展示系統運作流程
set -euo pipefail

DEMO_URL="http://localhost:30080"
PRED_URL="http://localhost:8000"

title() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $1"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Step 1: 確認現況 ──────────────────────────────────
title "Step 1 | 確認現況"
echo "[ Demo App Pods ]"
kubectl get pods -n demo
echo ""
echo "[ Smart Scaler Pods ]"
kubectl get pods -n smart-scaler
echo ""

# ── Step 2: Port-forward Prediction Service ───────────
title "Step 2 | 啟動 Port-Forward"
kubectl port-forward svc/prediction-service 8000:8000 -n smart-scaler &
PF_PID=$!
sleep 3

echo "[ Prediction Service Health ]"
curl -s "${PRED_URL}/health" | python3 -m json.tool
echo ""

# ── Step 3: 顯示當前預測 ───────────────────────────────
title "Step 3 | 當前 CPU 預測（未來 30 分鐘）"
curl -s "${PRED_URL}/predict?minutes_ahead=30" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(f'  最高預測 CPU: {data[\"max_predicted_cpu\"]}%')
print(f'  平均預測 CPU: {data[\"avg_predicted_cpu\"]}%')
print(f'  預測時間點數: {len(data[\"predictions\"])} 個')
print(f'  模型訓練時間: {data[\"model_trained_at\"]}')
"
echo ""

# ── Step 4: 啟動壓測 ──────────────────────────────────
title "Step 4 | 啟動壓測（120秒）"
echo "Watch replicas change:"
bash scripts/load-test.sh "$DEMO_URL" 120 15 85 &
LOAD_PID=$!

# ── Step 5: 即時觀察 pods ─────────────────────────────
title "Step 5 | 即時觀察 Pods 變化（30秒）"
timeout 30 kubectl get pods -n demo -w || true

echo ""
title "Step 6 | 30 秒後的狀態"
kubectl get pods -n demo
echo ""

echo "[ Scaler Controller 日誌 ]"
kubectl logs -n smart-scaler deployment/scaler-controller --tail=20
echo ""

# ── 清理 ──────────────────────────────────────────────
kill $PF_PID $LOAD_PID 2>/dev/null || true

title "✅ Demo 完成！"
echo "進一步觀察："
echo "  kubectl logs -n smart-scaler deployment/prediction-service -f"
echo "  kubectl logs -n smart-scaler deployment/scaler-controller -f"
