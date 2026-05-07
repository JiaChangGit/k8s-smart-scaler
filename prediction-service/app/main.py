import asyncio
import logging
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import FastAPI, HTTPException, BackgroundTasks
from fastapi.middleware.cors import CORSMiddleware

from .predictor import CPUPredictor
from .metrics_collector import PrometheusCollector
from .schemas import PredictionResponse, HealthResponse

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
)
logger = logging.getLogger(__name__)

# ──── 全域狀態 ────────────────────────────────────────────
predictor = CPUPredictor()
collector = PrometheusCollector()
_bg_running = False
RETRAIN_INTERVAL = 300  # 每 5 分鐘重訓


async def _periodic_retrain():
    """背景任務：定期重訓 Prophet 模型"""
    global _bg_running
    logger.info("背景重訓任務啟動")
    while _bg_running:
        try:
            metrics = await collector.fetch_metrics(lookback_hours=3)
            if metrics:
                predictor.train(metrics)
        except Exception as e:
            logger.error(f"重訓失敗: {e}", exc_info=True)
        await asyncio.sleep(RETRAIN_INTERVAL)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _bg_running
    # ── 啟動時 ──
    logger.info("🚀 Prediction Service 啟動中...")
    _bg_running = True

    # 立刻訓練一次
    metrics = await collector.fetch_metrics(lookback_hours=3)
    if metrics:
        predictor.train(metrics)

    task = asyncio.create_task(_periodic_retrain())

    yield

    # ── 關閉時 ──
    logger.info("🛑 Prediction Service 關閉中...")
    _bg_running = False
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass


# ──── FastAPI App ─────────────────────────────────────────
app = FastAPI(
    title="K8s Smart Scaler — Prediction Service",
    description="用 Prophet 預測 CPU 趨勢，實現 K8s 主動式擴縮",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.get("/health", response_model=HealthResponse)
async def health():
    """健康檢查，也回傳模型狀態"""
    return {
        "status": "healthy",
        "model_trained": predictor.is_trained,
        "last_training": predictor.last_training_time,
        "data_points": predictor.data_points_used,
        "timestamp": datetime.utcnow(),
    }


@app.get("/predict", response_model=PredictionResponse)
async def predict(minutes_ahead: int = 30):
    """
    回傳未來 minutes_ahead 分鐘的 CPU 預測。
    若模型未訓練，嘗試即時訓練後再預測。
    """
    if not predictor.is_trained:
        metrics = await collector.fetch_metrics(lookback_hours=3)
        if metrics:
            predictor.train(metrics)

    result = predictor.predict(minutes_ahead)
    if result is None:
        raise HTTPException(
            status_code=503,
            detail="模型尚未就緒，請稍後重試",
        )
    return result


@app.post("/train")
async def trigger_train(background_tasks: BackgroundTasks):
    """手動觸發模型重訓（非同步，立即回應）"""
    async def _train():
        metrics = await collector.fetch_metrics(lookback_hours=6)
        if metrics:
            predictor.train(metrics)

    background_tasks.add_task(_train)
    return {"message": "重訓已觸發", "timestamp": datetime.utcnow().isoformat()}


@app.get("/metrics/current")
async def current_metrics():
    """取得目前 CPU 使用率（即時）"""
    cpu = await collector.fetch_current_cpu()
    return {"current_cpu_percent": cpu, "timestamp": datetime.utcnow().isoformat()}
