"""
Scaler Controller
每隔 CHECK_INTERVAL 秒向 Prediction Service 拉取預測結果，
若預測 CPU > SCALE_UP_THRESHOLD，提前擴容；
若預測 CPU < SCALE_DOWN_THRESHOLD，縮減資源。
"""
import logging
import os
import time
from datetime import datetime
from typing import Optional

import httpx
from kubernetes import client, config
from kubernetes.client.exceptions import ApiException

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
)
logger = logging.getLogger(__name__)

# ──── 設定（全部可透過環境變數覆蓋）────────────────────────
PREDICTION_URL = os.getenv(
    "PREDICTION_SERVICE_URL", "http://prediction-service:8000"
)
TARGET_NAMESPACE = os.getenv("TARGET_NAMESPACE", "demo")
TARGET_DEPLOYMENT = os.getenv("TARGET_DEPLOYMENT", "demo-app")
SCALE_UP_THRESHOLD = float(os.getenv("SCALE_UP_THRESHOLD", "70.0"))
SCALE_DOWN_THRESHOLD = float(os.getenv("SCALE_DOWN_THRESHOLD", "30.0"))
MIN_REPLICAS = int(os.getenv("MIN_REPLICAS", "1"))
MAX_REPLICAS = int(os.getenv("MAX_REPLICAS", "10"))
CHECK_INTERVAL = int(os.getenv("CHECK_INTERVAL", "60"))
LOOKAHEAD_MINUTES = int(os.getenv("LOOKAHEAD_MINUTES", "30"))
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "120"))


class SmartScaler:
    def __init__(self):
        self._init_k8s()
        self.last_scale_time: Optional[datetime] = None
        self.last_replica_count: int = 0

    def _init_k8s(self):
        """自動判斷環境：in-cluster 或 local kubeconfig"""
        try:
            config.load_incluster_config()
            logger.info("✅ 使用 in-cluster K8s 設定")
        except config.ConfigException:
            config.load_kube_config()
            logger.info("✅ 使用本地 kubeconfig")
        self.apps_v1 = client.AppsV1Api()

    # ── K8s 操作 ──────────────────────────────────────────

    def get_current_replicas(self) -> int:
        try:
            dep = self.apps_v1.read_namespaced_deployment(
                name=TARGET_DEPLOYMENT, namespace=TARGET_NAMESPACE
            )
            return dep.spec.replicas or 1
        except ApiException as e:
            logger.error(f"無法讀取 deployment: {e}")
            return 1

    def scale_to(self, desired: int) -> bool:
        """
        安全地縮放 Deployment，包含 cooldown、邊界檢查。
        """
        # Cooldown 檢查
        if self.last_scale_time:
            elapsed = (datetime.utcnow() - self.last_scale_time).total_seconds()
            remaining = COOLDOWN_SECONDS - elapsed
            if remaining > 0:
                logger.info(f"⏱  Cooldown 中，還需等 {remaining:.0f} 秒")
                return False

        current = self.get_current_replicas()
        desired = max(MIN_REPLICAS, min(MAX_REPLICAS, desired))

        if desired == current:
            return False

        try:
            self.apps_v1.patch_namespaced_deployment(
                name=TARGET_DEPLOYMENT,
                namespace=TARGET_NAMESPACE,
                body={"spec": {"replicas": desired}},
            )
            direction = "⬆  SCALE UP" if desired > current else "⬇  SCALE DOWN"
            logger.info(
                f"{direction} | {TARGET_NAMESPACE}/{TARGET_DEPLOYMENT} "
                f"| {current} → {desired} replicas"
            )
            self.last_scale_time = datetime.utcnow()
            self.last_replica_count = desired
            return True
        except ApiException as e:
            logger.error(f"縮放操作失敗: {e}")
            return False

    # ── 預測拉取 ───────────────────────────────────────────

    def fetch_prediction(self) -> Optional[dict]:
        try:
            with httpx.Client(timeout=15.0) as http:
                resp = http.get(
                    f"{PREDICTION_URL}/predict",
                    params={"minutes_ahead": LOOKAHEAD_MINUTES},
                )
                resp.raise_for_status()
                return resp.json()
        except httpx.RequestError as e:
            logger.error(f"無法連接 Prediction Service: {e}")
        except Exception as e:
            logger.error(f"預測拉取失敗: {e}")
        return None

    # ── 決策邏輯 ───────────────────────────────────────────

    def decide_replicas(self, max_cpu: float, current: int) -> int:
        """
        根據預測的最高 CPU 決定目標 replica 數。
        Scale Up: CPU 超過閾值，按比例增加。
        Scale Down: CPU 低於閾值，逐步縮減（一次 -1）。
        """
        if max_cpu >= SCALE_UP_THRESHOLD:
            # 按比例計算需要的 replicas
            ratio = max_cpu / SCALE_UP_THRESHOLD
            desired = math.ceil(current * ratio)
            desired = max(current + 1, desired)  # 至少加 1
            logger.info(
                f"預測 CPU={max_cpu:.1f}% 超過閾值 {SCALE_UP_THRESHOLD}% → 擴容至 {desired}"
            )
            return desired

        elif max_cpu <= SCALE_DOWN_THRESHOLD:
            desired = max(MIN_REPLICAS, current - 1)
            logger.info(
                f"預測 CPU={max_cpu:.1f}% 低於閾值 {SCALE_DOWN_THRESHOLD}% → 縮容至 {desired}"
            )
            return desired

        else:
            logger.info(
                f"預測 CPU={max_cpu:.1f}% 在正常範圍內，維持 {current} replicas"
            )
            return current

    # ── 主迴圈 ─────────────────────────────────────────────

    def run_once(self):
        prediction = self.fetch_prediction()
        if prediction is None:
            return

        max_cpu = prediction["max_predicted_cpu"]
        avg_cpu = prediction["avg_predicted_cpu"]
        current = self.get_current_replicas()

        logger.info(
            f"📊 預測結果 | 未來 {LOOKAHEAD_MINUTES}min | "
            f"max={max_cpu:.1f}% avg={avg_cpu:.1f}% | 現有={current} replicas"
        )

        desired = self.decide_replicas(max_cpu, current)
        self.scale_to(desired)

    def run(self):
        logger.info("=" * 60)
        logger.info("🤖 SmartScaler 啟動")
        logger.info(f"   目標: {TARGET_NAMESPACE}/{TARGET_DEPLOYMENT}")
        logger.info(f"   擴容閾值: {SCALE_UP_THRESHOLD}% | 縮容閾值: {SCALE_DOWN_THRESHOLD}%")
        logger.info(f"   Replicas: {MIN_REPLICAS} ~ {MAX_REPLICAS}")
        logger.info(f"   檢查間隔: {CHECK_INTERVAL}s | 預測視窗: {LOOKAHEAD_MINUTES}min")
        logger.info("=" * 60)

        while True:
            try:
                self.run_once()
            except Exception as e:
                logger.error(f"主迴圈例外: {e}", exc_info=True)
            time.sleep(CHECK_INTERVAL)


# ── 補充 import ──
import math

if __name__ == "__main__":
    SmartScaler().run()
