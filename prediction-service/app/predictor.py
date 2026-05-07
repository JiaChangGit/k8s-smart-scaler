import logging
import math
import random
from datetime import datetime, timedelta
from typing import List, Dict, Optional

import pandas as pd
from prophet import Prophet

logger = logging.getLogger(__name__)


class CPUPredictor:
    """
    封裝 Facebook Prophet 模型。
    - train(): 用歷史 CPU 資料訓練
    - predict(): 預測未來 N 分鐘的 CPU 趨勢
    """

    def __init__(self):
        self.model: Optional[Prophet] = None
        self.last_training_time: Optional[datetime] = None
        self.data_points_used: int = 0
        self.is_trained: bool = False

    def train(self, metrics_data: List[Dict]) -> bool:
        """
        訓練 Prophet 模型。

        Args:
            metrics_data: [{'timestamp': datetime, 'cpu_usage': float}, ...]
        Returns:
            True 成功, False 失敗
        """
        if len(metrics_data) < 15:
            logger.warning(f"資料不足，需要至少 15 筆，現有 {len(metrics_data)} 筆")
            return False

        df = pd.DataFrame(metrics_data)
        df = df.rename(columns={"timestamp": "ds", "cpu_usage": "y"})
        df["ds"] = pd.to_datetime(df["ds"])

        # 去除異常值（3-sigma）
        mean_y = df["y"].mean()
        std_y = df["y"].std()
        df = df[(df["y"] >= mean_y - 3 * std_y) & (df["y"] <= mean_y + 3 * std_y)]
        df["y"] = df["y"].clip(0, 100)

        # Prophet 模型設定
        # changepoint_prior_scale: 越大對突變越敏感
        # seasonality_mode: multiplicative 適合 CPU 這種比例型資料
        self.model = Prophet(
            changepoint_prior_scale=0.05,
            seasonality_mode="multiplicative",
            daily_seasonality=True,
            weekly_seasonality=True,
            interval_width=0.95,
            uncertainty_samples=200,
        )

        try:
            self.model.fit(df)
            self.last_training_time = datetime.utcnow()
            self.data_points_used = len(df)
            self.is_trained = True
            logger.info(
                f"✅ 模型訓練完成 | 資料點: {len(df)} | 時間: {self.last_training_time}"
            )
            return True
        except Exception as e:
            logger.error(f"❌ 訓練失敗: {e}", exc_info=True)
            return False

    def predict(self, minutes_ahead: int = 30) -> Optional[Dict]:
        """
        預測未來 minutes_ahead 分鐘的 CPU 使用率。

        Returns:
            dict with predictions list, max/avg cpu, etc.
        """
        if not self.is_trained or self.model is None:
            logger.warning("模型尚未訓練")
            return None

        now = datetime.utcnow()
        future_dates = [now + timedelta(minutes=i) for i in range(1, minutes_ahead + 1)]
        future_df = pd.DataFrame({"ds": future_dates})

        try:
            forecast = self.model.predict(future_df)
        except Exception as e:
            logger.error(f"預測失敗: {e}")
            return None

        predictions = []
        for _, row in forecast.iterrows():
            predictions.append(
                {
                    "timestamp": row["ds"].isoformat(),
                    "predicted_cpu": round(max(0.0, float(row["yhat"])), 2),
                    "lower_bound": round(max(0.0, float(row["yhat_lower"])), 2),
                    "upper_bound": round(min(100.0, float(row["yhat_upper"])), 2),
                }
            )

        max_cpu = max(p["predicted_cpu"] for p in predictions)
        avg_cpu = sum(p["predicted_cpu"] for p in predictions) / len(predictions)

        return {
            "predictions": predictions,
            "max_predicted_cpu": round(max_cpu, 2),
            "avg_predicted_cpu": round(avg_cpu, 2),
            "prediction_time": now.isoformat(),
            "minutes_ahead": minutes_ahead,
            "model_trained_at": (
                self.last_training_time.isoformat()
                if self.last_training_time
                else None
            ),
        }
