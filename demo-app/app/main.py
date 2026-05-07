import math
import time
import os
import logging

from fastapi import FastAPI
from prometheus_fastapi_instrumentator import Instrumentator

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Demo App",
    description="K8S Smart Scaler 的目標服務，用於模擬 CPU 負載",
    version="1.0.0",
)

# 自動掛載 /metrics，供 Prometheus scrape
Instrumentator().instrument(app).expose(app)

POD_NAME = os.getenv("POD_NAME", "unknown")


@app.get("/")
def root():
    return {"app": "demo-app", "pod": POD_NAME, "version": "1.0.0"}


@app.get("/health")
def health():
    return {"status": "healthy", "pod": POD_NAME}


@app.get("/work")
def cpu_work(intensity: int = 50, duration: float = 1.0):
    """
    模擬 CPU 密集作業，intensity=0~100，duration 單位秒。
    用於 load test 觸發 CPU 高峰。
    """
    intensity = max(1, min(100, intensity))
    end = time.time() + duration
    result = 0.0
    iteration = 0

    while time.time() < end:
        # 根據 intensity 決定每次迴圈的工作量
        if iteration % 100 < intensity:
            for i in range(5000):
                result += math.sqrt(float(i + 1))
        else:
            time.sleep(0.001)
        iteration += 1

    return {
        "done": True,
        "intensity": intensity,
        "duration": duration,
        "pod": POD_NAME,
    }
