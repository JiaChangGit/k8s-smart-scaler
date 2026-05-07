FROM python:3.11-slim AS builder

WORKDIR /build

# Prophet 需要 gcc/g++ 編譯 pystan
RUN apt-get update && apt-get install -y \
    gcc g++ \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt


FROM python:3.11-slim

WORKDIR /app

# 安全：不以 root 執行
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser

# 從 builder 複製安裝好的套件
COPY --from=builder /usr/local /usr/local

COPY app/ ./app/

# ENV PATH=/home/appuser/.local/bin:$PATH
ENV PYTHONPATH=/app

USER appuser

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import httpx; httpx.get('http://localhost:8000/health').raise_for_status()"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
