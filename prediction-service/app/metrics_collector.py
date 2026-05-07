import logging
import math
import random
import os
from datetime import datetime, timedelta
from typing import List, Dict

import httpx

logger = logging.getLogger(__name__)

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
TARGET_NAMESPACE = os.getenv("TARGET_NAMESPACE", "demo")
TARGET_DEPLOYMENT = os.getenv("TARGET_DEPLOYMENT", "demo-app")


class PrometheusCollector:
    """從 Prometheus 拉取 CPU 歷史資料，供 Prophet 訓練用。"""

    def __init__(self):
        self.prometheus_url = PROMETHEUS_URL

    async def fetch_metrics(self, lookback_hours: int = 2) -> List[Dict]:
        """
        拉取過去 lookback_hours 小時的 CPU 資料。
        若 Prometheus 不可達，自動降級為合成資料（方便本地 demo）。
        """
        end_time = datetime.utcnow()
        start_time = end_time - timedelta(hours=lookback_hours)

        # PromQL: 計算 demo-app pod 平均 CPU 使用率（%）
        query = (
            f'avg(rate(container_cpu_usage_seconds_total{{'
            f'namespace="{TARGET_NAMESPACE}",'
            f'pod=~"{TARGET_DEPLOYMENT}-.*",'
            f'container!="POD",container!=""}}'
            f'[5m])) * 100'
        )

        params = {
            "query": query,
            "start": start_time.timestamp(),
            "end": end_time.timestamp(),
            "step": "60",  # 每分鐘一個點
        }

        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.get(
                    f"{self.prometheus_url}/api/v1/query_range",
                    params=params,
                )
                response.raise_for_status()
                data = response.json()

            if data["status"] != "success":
                logger.error(f"Prometheus 查詢失敗: {data}")
                return self._generate_synthetic_data()

            results = data["data"]["result"]
            if not results:
                logger.warning("Prometheus 無資料，使用合成資料")
                return self._generate_synthetic_data()

            metrics = []
            for value in results[0]["values"]:
                ts = datetime.fromtimestamp(float(value[0]))
                cpu = float(value[1])
                metrics.append({"timestamp": ts, "cpu_usage": round(cpu, 4)})

            logger.info(f"從 Prometheus 取得 {len(metrics)} 筆 CPU 資料")
            return metrics

        except Exception as e:
            logger.warning(f"無法連接 Prometheus ({e})，改用合成資料")
            return self._generate_synthetic_data()

    async def fetch_current_cpu(self) -> float:
        """取得當前 CPU 使用率（%）"""
        query = (
            f'avg(rate(container_cpu_usage_seconds_total{{'
            f'namespace="{TARGET_NAMESPACE}",'
            f'pod=~"{TARGET_DEPLOYMENT}-.*",'
            f'container!="POD",container!=""}}'
            f'[1m])) * 100'
        )
        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(
                    f"{self.prometheus_url}/api/v1/query",
                    params={"query": query},
                )
                response.raise_for_status()
                data = response.json()

            if data["data"]["result"]:
                return round(float(data["data"]["result"][0]["value"][1]), 2)
        except Exception as e:
            logger.warning(f"無法取得當前 CPU: {e}")
        return 0.0

    def _generate_synthetic_data(self) -> List[Dict]:
        """
        生成符合日常 CPU 模式的合成資料（用於 demo 或 Prometheus 不可達時）。
        模擬：早上 9 點和下午 3 點各有一個高峰，凌晨低谷。
        """
        data = []
        now = datetime.utcnow()
        n = 120  # 2 小時，每分鐘一筆

        for i in range(n):
            ts = now - timedelta(minutes=n - i)
            hour = ts.hour + ts.minute / 60.0

            # 雙峰模型（9am peak + 3pm peak）
            morning_peak = 30 * math.exp(-0.5 * ((hour - 9) / 1.5) ** 2)
            afternoon_peak = 25 * math.exp(-0.5 * ((hour - 15) / 2.0) ** 2)
            base = 10 + morning_peak + afternoon_peak

            # 加入隨機噪聲
            noise = random.gauss(0, 3)
            cpu = max(5.0, min(90.0, base + noise))
            data.append({"timestamp": ts, "cpu_usage": cpu})

        logger.info(f"生成 {len(data)} 筆合成 CPU 資料")
        return data
