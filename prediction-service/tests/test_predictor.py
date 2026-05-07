"""
Unit tests for CPUPredictor
Run: cd prediction-service && python -m pytest tests/ -v
"""
import math
import random
import sys
import os
from datetime import datetime, timedelta

import pytest

# 讓 tests 能 import app/
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.predictor import CPUPredictor


def make_data(n: int = 120) -> list:
    """生成模擬 CPU 資料"""
    data = []
    now = datetime.utcnow()
    for i in range(n):
        ts = now - timedelta(minutes=n - i)
        hour = ts.hour + ts.minute / 60
        base = 20 + 30 * math.sin((hour - 6) * math.pi / 12)
        cpu = max(5.0, min(95.0, base + random.gauss(0, 3)))
        data.append({"timestamp": ts, "cpu_usage": cpu})
    return data


class TestCPUPredictor:
    def test_initial_state(self):
        p = CPUPredictor()
        assert p.is_trained is False
        assert p.model is None

    def test_train_with_insufficient_data(self):
        p = CPUPredictor()
        result = p.train([])
        assert result is False
        assert p.is_trained is False

    def test_train_success(self):
        p = CPUPredictor()
        data = make_data(120)
        result = p.train(data)
        assert result is True
        assert p.is_trained is True
        assert p.data_points_used > 0
        assert p.last_training_time is not None

    def test_predict_without_training(self):
        p = CPUPredictor()
        result = p.predict(30)
        assert result is None

    def test_predict_returns_correct_structure(self):
        p = CPUPredictor()
        p.train(make_data(120))
        result = p.predict(30)

        assert result is not None
        assert "predictions" in result
        assert len(result["predictions"]) == 30
        assert "max_predicted_cpu" in result
        assert "avg_predicted_cpu" in result

    def test_predict_cpu_within_valid_range(self):
        p = CPUPredictor()
        p.train(make_data(120))
        result = p.predict(30)

        for point in result["predictions"]:
            assert 0.0 <= point["predicted_cpu"] <= 100.0
            assert point["lower_bound"] >= 0.0
            assert point["upper_bound"] <= 100.0

    def test_predict_different_horizons(self):
        p = CPUPredictor()
        p.train(make_data(120))

        for horizon in [10, 30, 60]:
            result = p.predict(horizon)
            assert len(result["predictions"]) == horizon
