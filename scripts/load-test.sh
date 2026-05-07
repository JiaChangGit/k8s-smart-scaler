#!/usr/bin/env bash
set -euo pipefail

DEMO_URL="${1:-http://localhost:30080}"
DURATION="${2:-120}"
CONCURRENCY="${3:-15}"
INTENSITY="${4:-85}"

echo "🔥 開始壓測..."
echo "   目標: ${DEMO_URL}"
echo "   時長: ${DURATION}s | 並發: ${CONCURRENCY} | 強度: ${INTENSITY}"
echo ""

TARGET="${DEMO_URL}/work?intensity=${INTENSITY}&duration=2"

# hey → ab → curl，依序降級
if command -v hey >/dev/null 2>&1 && hey --version >/dev/null 2>&1; then
    echo "（使用 hey）"
    hey -z "${DURATION}s" -c "$CONCURRENCY" "$TARGET"

elif command -v ab >/dev/null 2>&1; then
    echo "（使用 ab）"
    # ab 不支援 -t + query string 的 & 符號，要加引號
    ab -t "$DURATION" -c "$CONCURRENCY" "${TARGET}"

else
    echo "（使用 curl 迴圈）"
    end=$((SECONDS + DURATION))
    count=0
    while [ $SECONDS -lt $end ]; do
        for _ in $(seq 1 "$CONCURRENCY"); do
            curl -sf "$TARGET" >/dev/null &
        done
        wait
        count=$((count + CONCURRENCY))
        echo "  已送出 ${count} 請求 | 剩餘 $((end - SECONDS))s"
    done
fi

echo ""
echo "✅ 壓測完成！"
echo "   kubectl get pods -n demo -w"
