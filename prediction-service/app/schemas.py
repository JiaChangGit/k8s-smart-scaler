from pydantic import BaseModel
from datetime import datetime
from typing import Optional, List


class PredictionPoint(BaseModel):
    timestamp: str
    predicted_cpu: float
    lower_bound: float
    upper_bound: float


class PredictionResponse(BaseModel):
    predictions: List[PredictionPoint]
    max_predicted_cpu: float
    avg_predicted_cpu: float
    prediction_time: str
    minutes_ahead: int
    model_trained_at: Optional[str] = None


class HealthResponse(BaseModel):
    status: str
    model_trained: bool
    last_training: Optional[datetime] = None
    data_points: Optional[int] = None
    timestamp: datetime
