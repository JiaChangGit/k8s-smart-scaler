#!/usr/bin/env bash
# 壓測腳本：對 demo-app 施加 CPU 負載，觸發預測縮放
set -euo pipefail

DEMO_URL="${1:-http://localhost:30080}"
DURATION="${2:-120}"       # 秒
CONCURRENCY="${3:-15}"     # 並發數
INTENSITY="${4:-85}"       # CPU 強度 0~100

echo "🔥 開始壓測..."
echo "   目標: ${DEMO_URL}"
echo "   時長: ${DURATION}s | 並發: ${CONCURRENCY} | 強度: ${INTENSITY}"
echo ""

# 使用 hey 工具壓測
if command -v hey >/dev/null 2>&1; then
    hey -z "${DURATION}s" \
        -c "$CONCURRENCY" \
        "${DEMO_URL}/work?intensity=${INTENSITY}&duration=2"
else
    # 降級：使用 curl 迴圈
    echo "（hey 未安裝，改用 curl 迴圈）"
    end=$((SECONDS + DURATION))
    count=0
    while [ $SECONDS -lt $end ]; do
        for _ in $(seq 1 "$CONCURRENCY"); do
            curl -sf "${DEMO_URL}/work?intensity=${INTENSITY}&duration=2" >/dev/null &
        done
        wait
        count=$((count + CONCURRENCY))
        remaining=$((end - SECONDS))
        echo "  已送出 ${count} 請求 | 剩餘 ${remaining}s"
    done
fi

echo ""
echo "✅ 壓測完成！觀察 pods 變化："
echo "   kubectl get pods -n demo -w"
