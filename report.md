# K8s Smart Scaler 技術報告

## 摘要

K8s Smart Scaler 是一個「預測式自動擴縮容」（Predictive Autoscaling）的 Kubernetes 範例系統。傳統的 Horizontal Pod Autoscaler，簡稱 HPA，通常依照當下或最近一段時間的 CPU、Memory、Custom Metrics 做反應；本專案的核心想法則是先收集歷史 CPU 指標，再使用 Prophet 做時間序列預測（Time Series Forecasting），提前判斷未來一段時間 CPU 是否會升高，最後由自製 controller 主動調整 Deployment replicas。

本報告會從系統架構、關鍵技術、資料流 trace、核心程式實作、Kubernetes 部署、安全權限、測試與 CI/CD 等面向，完整說明這個專案如何運作。報告中的重要名詞會同時標示中文與英文，並盡量用具體例子說明。

## 專案目標

本專案要解決的問題是：如果流量即將變大，是否可以在 CPU 真正衝高前就先擴容？

傳統 reactive scaling，也就是反應式擴縮，通常流程如下：

```text
流量增加 -> CPU 升高 -> 指標超過門檻 -> HPA 判斷 -> 建立更多 Pod
```

這種方式可行，但在實務上可能遇到延遲：

- Metrics scrape 有時間間隔，例如每 15 秒或 60 秒。
- HPA 判斷有同步週期。
- 新 Pod 需要 image pull、container start、readiness probe。
- 若應用啟動較慢，擴容完成時壓力可能已經累積。

本專案採用 predictive scaling，也就是預測式擴縮：

```text
歷史 CPU -> 時間序列模型 -> 預測未來 CPU -> 提前擴容 -> 流量高峰前 Pod 已就緒
```

這不是要取代 HPA，而是展示一種可以和 HPA、KEDA、Custom Metrics API 並存的自訂擴縮思路。

## 技術總覽

| 技術 | 英文關鍵字 | 在本專案的角色 |
| --- | --- | --- |
| Kubernetes | Kubernetes, K8s, Container Orchestration | 管理 Pod、Deployment、Service、Namespace、RBAC |
| Deployment | Kubernetes Deployment | `demo-app` 是被擴縮的目標，`prediction-service` 和 `scaler-controller` 也是 Deployment |
| Replica | Replica, Pod Replica | controller 最終調整的數值 |
| Service | Kubernetes Service | 提供 cluster 內部 DNS 與穩定存取位置 |
| Namespace | Namespace | 分離 `demo`、`smart-scaler`、`monitoring` |
| RBAC | Role-Based Access Control | 讓 controller 有權讀取與 patch Deployment |
| FastAPI | FastAPI, ASGI Web Framework | 建立 demo app 與 prediction API |
| Prometheus | Prometheus, Monitoring, Time Series Database | 收集與查詢 CPU metrics |
| PromQL | Prometheus Query Language | 查詢 CPU 時間序列 |
| Prophet | Prophet, Time Series Forecasting | 預測未來 CPU |
| pandas | DataFrame, Data Processing | 整理模型訓練資料 |
| httpx | HTTP Client | 呼叫 Prometheus API 與 Prediction Service |
| Docker | Container Image | 封裝三個服務 |
| Docker Compose | Local Multi-container Runtime | 本機快速體驗監控與 API |
| kind | Kubernetes in Docker | 本機建立 K8s cluster |
| Helm | Kubernetes Package Manager | 安裝 kube-prometheus-stack |
| GitHub Actions | CI/CD Pipeline | 測試、建立 Docker images、預留部署流程 |
| HPA | Horizontal Pod Autoscaler | Kubernetes 原生水平自動擴縮機制，本專案用自製 controller 對照與延伸 |

## 系統架構

整體架構如下：

```text
User / load-test.sh
        |
        v
    demo-app
  FastAPI /work
        |
        | exposes /metrics
        v
   Prometheus
  scrape metrics
        |
        | PromQL query_range
        v
prediction-service
 PrometheusCollector
 CPUPredictor / Prophet
        |
        | /predict
        v
scaler-controller
 SmartScaler decision
        |
        | Kubernetes API patch Deployment
        v
Kubernetes Deployment replicas
```

三個服務的責任切分很清楚：

1. `demo-app` 負責製造可觀測的 CPU 負載。
2. `prediction-service` 負責把 Prometheus 的歷史資料轉成模型預測。
3. `scaler-controller` 負責把預測結果轉成 Kubernetes 擴縮操作。

這種分層設計的好處是，每個元件都可以獨立替換。例如 Prophet 可以換成 ARIMA、LSTM、XGBoost 或其他 forecasting model；Prometheus 可以換成 Thanos、VictoriaMetrics 或雲端監控 API；controller 的決策策略也可以從固定門檻改成成本最佳化策略。

## 目錄與檔案角色

```text
demo-app/
  app/main.py                 # 目標服務，提供 /work 與 /metrics
  Dockerfile                  # demo-app image
  requirements.txt            # FastAPI 與 prometheus instrumentator

prediction-service/
  app/main.py                 # Prediction API 與背景重訓任務
  app/metrics_collector.py    # Prometheus 查詢與 fallback synthetic data
  app/predictor.py            # Prophet 訓練與預測
  app/schemas.py              # Pydantic response models
  tests/test_predictor.py     # CPUPredictor 單元測試
  Dockerfile                  # prediction-service image

scaler-controller/
  controller.py               # SmartScaler 主迴圈、決策、K8s patch
  Dockerfile                  # controller image
  requirements.txt            # kubernetes client 與 httpx

k8s/
  namespace.yaml              # smart-scaler 與 demo namespace
  demo-app/                   # demo-app Deployment 與 Service
  prediction-service/         # prediction-service Deployment、Service、ConfigMap
  scaler-controller/          # controller Deployment
  rbac/                       # ServiceAccount、ClusterRole、ClusterRoleBinding
  monitoring/                 # Prometheus Helm values 與 ServiceMonitor

scripts/
  setup.sh                    # 建立 kind、安裝監控、build/load image、部署
  load-test.sh                # 對 demo-app 產生壓力
  demo.sh                     # 展示健康檢查、預測、壓測與擴縮觀察
  deploy-local.sh             # 模擬 CI/CD 後本地部署
  cleanup.sh                  # 清理環境
```

## 關鍵名詞深入教學

### Kubernetes / K8s / 容器編排

Kubernetes 是 container orchestration system，也就是容器編排系統。它負責把 container image 跑成 Pod，並提供故障重啟、服務發現、水平擴縮、滾動更新等能力。

在本專案中，Kubernetes 最重要的資源是：

- Deployment：描述「我要跑幾個 Pod、用什麼 image、如何健康檢查」。
- Pod：Kubernetes 最小執行單位，裡面跑 container。
- Service：提供穩定的存取入口與 DNS 名稱。
- Namespace：邏輯隔離區。
- RBAC：控制誰可以操作哪些資源。

### Deployment / 部署物件

Deployment 是 Kubernetes 中管理 stateless application 的常用資源。它會透過 ReplicaSet 管理 Pod 數量。當 controller patch Deployment 的 `spec.replicas`，Kubernetes 會自動讓實際 Pod 數量收斂到指定數字。

本專案的 scaler-controller 實際執行的是：

```python
self.apps_v1.patch_namespaced_deployment(
    name=TARGET_DEPLOYMENT,
    namespace=TARGET_NAMESPACE,
    body={"spec": {"replicas": desired}},
)
```

意思是：對指定 namespace 和 deployment 發送 patch request，把 replicas 改成 `desired`。

假設目前 `demo-app` 是 1 個 replica，controller 決定 `desired = 3`，Kubernetes 會建立額外 2 個 Pod。這是 declarative control 的典型例子：使用者宣告期望狀態，Kubernetes 負責讓實際狀態接近期望狀態。

### Replica / 副本數

Replica 是同一個應用 Pod 的副本數。更多 replicas 通常代表可以承受更多請求，但也會消耗更多 CPU、Memory 和節點資源。

本專案的 replica 決策邏輯在 `scaler-controller/controller.py` 的 `decide_replicas()`：

```python
if max_cpu >= SCALE_UP_THRESHOLD:
    ratio = max_cpu / SCALE_UP_THRESHOLD
    desired = math.ceil(current * ratio)
    desired = max(current + 1, desired)
```

例子：

- 現在 replicas = 2。
- 預測最大 CPU = 91%。
- 擴容門檻 = 70%。
- ratio = 91 / 70 = 1.3。
- desired = ceil(2 * 1.3) = 3。
- 最終 replicas = 3。

這是按比例擴容（proportional scale up）的簡化實作。

### Service / 服務發現

Kubernetes Service 提供穩定 DNS。Pod 會重建、IP 會變，但 Service 名稱可以保持不變。

本專案中：

- `prediction-service.smart-scaler.svc.cluster.local:8000` 是 controller 存取 Prediction Service 的 cluster DNS。
- `demo-app` Service 使用 NodePort `30080`，方便本機從 `http://localhost:30080` 打到 kind cluster 裡的 demo-app。

### RBAC / Role-Based Access Control / 角色權限控制

RBAC 用來限制 Pod 裡的程式能操作 Kubernetes API 的範圍。scaler-controller 需要 patch Deployment，因此必須有對 `deployments` 和 `deployments/scale` 的 `patch`、`update` 權限。

`k8s/rbac/clusterrole.yaml` 給予：

```yaml
apiGroups: ["apps"]
resources: ["deployments", "deployments/scale"]
verbs: ["get", "list", "watch", "update", "patch"]
```

這是必要權限。沒有這些權限時，controller 呼叫 Kubernetes API 會得到 403 Forbidden。

### Prometheus / 指標監控系統

Prometheus 是 time series database，會定期 scrape HTTP endpoint，將 metrics 以時間序列形式存起來。

本專案有兩種 Prometheus 設定：

1. Docker Compose 模式：使用 `monitoring/prometheus.yml` 固定 scrape `demo-app:8000` 和 `prediction-service:8000`。
2. Kubernetes 模式：使用 kube-prometheus-stack，並透過 pod annotation 找到要 scrape 的 Pod。

`demo-app` 的 Deployment 上有：

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8000"
prometheus.io/path: "/metrics"
```

這告訴 Prometheus：「這個 Pod 可以抓 metrics，路徑是 `/metrics`，port 是 8000。」

### PromQL / Prometheus Query Language

PromQL 是 Prometheus 的查詢語言。本專案查 CPU 的核心 query 是：

```promql
avg(rate(container_cpu_usage_seconds_total{
  namespace="demo",
  pod=~"demo-app-.*",
  container!="POD",
  container!=""
}[5m])) * 100
```

逐段解釋：

- `container_cpu_usage_seconds_total`：container 累積使用 CPU 的秒數，是 counter 指標。
- `rate(...[5m])`：計算最近 5 分鐘每秒增加速率，將 counter 轉成使用率概念。
- `namespace="demo"`：只看 `demo` namespace。
- `pod=~"demo-app-.*"`：使用 regex 選出 demo-app 的 Pod。
- `container!="POD", container!=""`：排除 pause container 和空 container name。
- `avg(...)`：多個 Pod 時取平均。
- `* 100`：轉成百分比表示。

重要觀念：counter 不能直接看瞬間值。`container_cpu_usage_seconds_total` 只會一直增加，必須用 `rate()` 或 `irate()` 才能轉成一段時間內的變化率。

### Prophet / 時間序列預測

Prophet 是 Meta/Facebook 開源的 time series forecasting library。它適合處理有趨勢（trend）、季節性（seasonality）、假日效應（holiday effects）的資料。

本專案使用 Prophet 預測 CPU：

```python
self.model = Prophet(
    changepoint_prior_scale=0.05,
    seasonality_mode="multiplicative",
    daily_seasonality=True,
    weekly_seasonality=True,
    interval_width=0.95,
    uncertainty_samples=200,
)
```

重要參數：

- `changepoint_prior_scale`：變化點敏感度。越大越容易追隨突然變化，但也可能 overfit。
- `seasonality_mode="multiplicative"`：乘法季節性，適合波動幅度會隨基準值變大的資料。
- `daily_seasonality=True`：考慮每日週期，例如上班時間 CPU 較高。
- `weekly_seasonality=True`：考慮每週週期，例如平日與假日流量不同。
- `interval_width=0.95`：預測區間寬度，本專案會回傳 lower_bound 和 upper_bound。
- `uncertainty_samples=200`：用於估計不確定性的抽樣數。

Prophet 要求欄位名稱固定：

- `ds`：timestamp，時間欄位。
- `y`：target value，要預測的值。

所以本專案在訓練前做欄位轉換：

```python
df = pd.DataFrame(metrics_data)
df = df.rename(columns={"timestamp": "ds", "cpu_usage": "y"})
df["ds"] = pd.to_datetime(df["ds"])
```

### Outlier / 異常值 與 3-sigma

在監控資料中，可能出現短暫尖峰、空值、抓取錯誤或不合理數字。若直接餵給模型，模型可能被異常值影響。

本專案用 3-sigma rule 過濾：

```python
mean_y = df["y"].mean()
std_y = df["y"].std()
df = df[(df["y"] >= mean_y - 3 * std_y) & (df["y"] <= mean_y + 3 * std_y)]
df["y"] = df["y"].clip(0, 100)
```

概念是：如果資料大致接近常態分布，約 99.7% 的資料會落在平均值正負三個標準差內。超出範圍的點可能是異常值。

例子：

- 平均 CPU = 30。
- 標準差 = 10。
- 合理範圍 = 0 到 60。
- 如果某筆 CPU = 300，明顯不合理，會被移除。

最後 `clip(0, 100)` 則保證 CPU 百分比落在 0 到 100。

## 重要功能 Trace：從負載到擴容

這一節逐步 trace 系統最重要的功能：使用者產生 CPU 負載後，系統如何收集、預測、決策、擴容。

### Trace 1：產生 CPU 負載

入口：

```text
GET /work?intensity=85&duration=2
```

檔案：

```text
demo-app/app/main.py
```

核心程式：

```python
@app.get("/work")
def cpu_work(intensity: int = 50, duration: float = 1.0):
    intensity = max(1, min(100, intensity))
    end = time.time() + duration
    result = 0.0
    iteration = 0

    while time.time() < end:
        if iteration % 100 < intensity:
            for i in range(5000):
                result += math.sqrt(float(i + 1))
        else:
            time.sleep(0.001)
        iteration += 1
```

實作細節：

- `intensity` 被限制在 1 到 100，避免傳入負數或過大值。
- `duration` 控制這次 CPU work 持續幾秒。
- 當 `iteration % 100 < intensity` 時，執行大量 `math.sqrt()`。
- 否則 `sleep(0.001)`，讓 CPU 有空檔。

例子：

- `intensity=85` 代表每 100 次迴圈中，約 85 次做 CPU 運算，15 次短暫 sleep。
- `intensity=20` 則大部分時間 sleep，CPU 壓力較低。

這種做法不依賴外部資料庫或第三方服務，很適合 demo autoscaling。

### Trace 2：暴露 metrics

檔案：

```text
demo-app/app/main.py
```

核心程式：

```python
Instrumentator().instrument(app).expose(app)
```

這行使用 `prometheus-fastapi-instrumentator` 自動為 FastAPI 掛上 `/metrics` endpoint。Prometheus scrape 後可以取得 HTTP request 數量、latency、status code 等 metrics。

Kubernetes 模式下，demo-app Deployment 也設定了 scrape annotation：

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8000"
prometheus.io/path: "/metrics"
```

注意：Prediction Service 主要查的是 `container_cpu_usage_seconds_total`，這個指標通常來自 Kubernetes/cAdvisor，而不是 demo-app 自己的 FastAPI `/metrics`。demo-app 的 `/metrics` 仍有價值，因為它提供 HTTP 層面的可觀測性，例如 request rate 和 latency。

### Trace 3：Prometheus scrape 與儲存時間序列

Docker Compose 模式的 scrape 設定：

```yaml
scrape_configs:
  - job_name: "demo-app"
    static_configs:
      - targets: ["demo-app:8000"]
    metrics_path: "/metrics"
```

Kubernetes 模式使用 kube-prometheus-stack：

```yaml
additionalScrapeConfigs:
  - job_name: "pod-annotation-scrape"
    kubernetes_sd_configs:
      - role: pod
```

`kubernetes_sd_configs` 是 Kubernetes service discovery。它會從 Kubernetes API 找 Pod，再依 relabel rules 決定哪些 Pod 要 scrape。

本專案的 relabel 邏輯重點：

```yaml
- source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
  action: keep
  regex: "true"
```

意思是：只有 annotation `prometheus.io/scrape: "true"` 的 Pod 會被保留。

### Trace 4：Prediction Service 查詢 Prometheus

檔案：

```text
prediction-service/app/metrics_collector.py
```

核心方法：

```python
async def fetch_metrics(self, lookback_hours: int = 2) -> List[Dict]:
```

它會產生查詢時間範圍：

```python
end_time = datetime.utcnow()
start_time = end_time - timedelta(hours=lookback_hours)
```

然後呼叫 Prometheus HTTP API：

```python
response = await client.get(
    f"{self.prometheus_url}/api/v1/query_range",
    params=params,
)
```

這裡使用的是 `/api/v1/query_range`，不是 `/api/v1/query`。

差異：

- `query`：查某一個時間點的瞬間值。
- `query_range`：查一段時間範圍內的序列值。

模型訓練需要歷史序列，所以使用 `query_range`。

參數：

```python
params = {
    "query": query,
    "start": start_time.timestamp(),
    "end": end_time.timestamp(),
    "step": "60",
}
```

`step="60"` 表示每 60 秒取一個資料點。若 lookback 是 3 小時，理想上會得到約 180 筆資料。

### Trace 5：Prometheus 結果轉為模型資料

Prometheus API 回傳格式中，資料點通常是：

```json
[
  [timestamp, "value"],
  [timestamp, "value"]
]
```

本專案轉換為：

```python
metrics = []
for value in results[0]["values"]:
    ts = datetime.fromtimestamp(float(value[0]))
    cpu = float(value[1])
    metrics.append({"timestamp": ts, "cpu_usage": round(cpu, 4)})
```

最後資料長這樣：

```python
[
    {"timestamp": datetime(...), "cpu_usage": 12.3456},
    {"timestamp": datetime(...), "cpu_usage": 18.9012},
]
```

這個格式是專案內部資料交換格式，接著會送進 `CPUPredictor.train()`。

### Trace 6：Prometheus 不可用時使用合成資料

如果 Prometheus 查不到資料或連線失敗，系統不會直接中斷，而是 fallback 到 synthetic data：

```python
return self._generate_synthetic_data()
```

合成資料模擬一天中兩個高峰：

```python
morning_peak = 30 * math.exp(-0.5 * ((hour - 9) / 1.5) ** 2)
afternoon_peak = 25 * math.exp(-0.5 * ((hour - 15) / 2.0) ** 2)
base = 10 + morning_peak + afternoon_peak
noise = random.gauss(0, 3)
cpu = max(5.0, min(90.0, base + noise))
```

這裡使用 Gaussian-like peak：

- 早上 9 點有一個高峰。
- 下午 3 點有一個高峰。
- `random.gauss(0, 3)` 加入噪聲，讓資料更像真實監控數據。

這個設計很適合 demo，因為即使 Prometheus 尚未收集到足夠資料，Prediction Service 仍能訓練與回傳預測。缺點是，在 production 中不應悄悄使用 synthetic data 做真實擴縮，否則可能根據假資料做錯決策。正式環境應把 fallback 改成「標記 degraded 狀態」或「拒絕擴縮」。

### Trace 7：訓練 Prophet 模型

檔案：

```text
prediction-service/app/predictor.py
```

入口：

```python
predictor.train(metrics)
```

最少資料量檢查：

```python
if len(metrics_data) < 15:
    logger.warning(...)
    return False
```

為什麼需要最少資料量？

時間序列模型需要足夠資料才能估計趨勢。若只有 2 到 3 筆資料，模型無法可靠判斷波動、週期或變化點。這裡設定 15 筆是 demo-friendly 的低門檻；真實系統通常應該要求更多資料，例如至少數小時到數天，取決於 workload 的週期性。

轉換 Prophet 欄位：

```python
df = pd.DataFrame(metrics_data)
df = df.rename(columns={"timestamp": "ds", "cpu_usage": "y"})
df["ds"] = pd.to_datetime(df["ds"])
```

清理資料：

```python
mean_y = df["y"].mean()
std_y = df["y"].std()
df = df[(df["y"] >= mean_y - 3 * std_y) & (df["y"] <= mean_y + 3 * std_y)]
df["y"] = df["y"].clip(0, 100)
```

建立模型並訓練：

```python
self.model = Prophet(...)
self.model.fit(df)
```

訓練完成後更新狀態：

```python
self.last_training_time = datetime.utcnow()
self.data_points_used = len(df)
self.is_trained = True
```

這些欄位會被 `/health` 回傳，讓使用者知道模型是否已經就緒。

### Trace 8：背景定期重訓

檔案：

```text
prediction-service/app/main.py
```

Prediction Service 使用 FastAPI lifespan 啟動背景任務：

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    _bg_running = True
    metrics = await collector.fetch_metrics(lookback_hours=3)
    if metrics:
        predictor.train(metrics)

    task = asyncio.create_task(_periodic_retrain())
    yield
    _bg_running = False
    task.cancel()
```

重訓任務：

```python
RETRAIN_INTERVAL = 300

async def _periodic_retrain():
    while _bg_running:
        metrics = await collector.fetch_metrics(lookback_hours=3)
        if metrics:
            predictor.train(metrics)
        await asyncio.sleep(RETRAIN_INTERVAL)
```

意思是：

- 服務啟動時先訓練一次。
- 之後每 300 秒，也就是 5 分鐘，重新拉取最近 3 小時資料並重訓。
- 關閉服務時取消背景任務。

這是簡單但清楚的 online retraining 設計。更進階的做法可以加入：

- 模型版本（model version）
- 訓練耗時 metrics
- 訓練失敗告警
- 只有資料變化足夠時才重訓
- 模型 warm swap，避免預測時讀到半更新狀態

### Trace 9：預測未來 CPU

Prediction API：

```text
GET /predict?minutes_ahead=30
```

如果模型還沒訓練，會嘗試即時訓練：

```python
if not predictor.is_trained:
    metrics = await collector.fetch_metrics(lookback_hours=3)
    if metrics:
        predictor.train(metrics)
```

接著呼叫：

```python
result = predictor.predict(minutes_ahead)
```

在 `CPUPredictor.predict()` 中，會建立未來時間點：

```python
now = datetime.utcnow()
future_dates = [now + timedelta(minutes=i) for i in range(1, minutes_ahead + 1)]
future_df = pd.DataFrame({"ds": future_dates})
```

若 `minutes_ahead=30`，會產生未來 1 到 30 分鐘，每分鐘一筆。

Prophet 預測：

```python
forecast = self.model.predict(future_df)
```

Prophet 回傳欄位包含：

- `yhat`：預測值。
- `yhat_lower`：預測下界。
- `yhat_upper`：預測上界。

本專案包裝成：

```python
{
    "timestamp": row["ds"].isoformat(),
    "predicted_cpu": round(max(0.0, float(row["yhat"])), 2),
    "lower_bound": round(max(0.0, float(row["yhat_lower"])), 2),
    "upper_bound": round(min(100.0, float(row["yhat_upper"])), 2),
}
```

注意：

- `predicted_cpu` 下限被限制為 0。
- `upper_bound` 上限被限制為 100。
- 這符合 CPU percentage 的合理範圍。

最後計算 summary：

```python
max_cpu = max(p["predicted_cpu"] for p in predictions)
avg_cpu = sum(p["predicted_cpu"] for p in predictions) / len(predictions)
```

`scaler-controller` 使用的是 `max_predicted_cpu`，不是平均值。這是一種保守策略：只要預測視窗內有高峰，就提前擴容。

### Trace 10：Controller 拉取預測

檔案：

```text
scaler-controller/controller.py
```

主迴圈：

```python
while True:
    try:
        self.run_once()
    except Exception as e:
        logger.error(...)
    time.sleep(CHECK_INTERVAL)
```

每次 `run_once()` 做四件事：

1. 呼叫 Prediction Service。
2. 讀取目前 Deployment replicas。
3. 根據 `max_predicted_cpu` 決定 desired replicas。
4. patch Kubernetes Deployment。

呼叫 Prediction Service：

```python
with httpx.Client(timeout=15.0) as http:
    resp = http.get(
        f"{PREDICTION_URL}/predict",
        params={"minutes_ahead": LOOKAHEAD_MINUTES},
    )
    resp.raise_for_status()
    return resp.json()
```

Kubernetes manifest 裡設定：

```yaml
PREDICTION_SERVICE_URL:
  value: "http://prediction-service.smart-scaler.svc.cluster.local:8000"
LOOKAHEAD_MINUTES:
  value: "30"
CHECK_INTERVAL:
  value: "60"
```

所以 controller 預設每 60 秒查詢一次未來 30 分鐘預測。

### Trace 11：讀取目前 replicas

```python
dep = self.apps_v1.read_namespaced_deployment(
    name=TARGET_DEPLOYMENT,
    namespace=TARGET_NAMESPACE
)
return dep.spec.replicas or 1
```

這使用 Kubernetes Python client 的 AppsV1Api。`read_namespaced_deployment` 讀取 Deployment spec，而不是直接數 Pod。這很合理，因為 controller 要修改的也是 Deployment spec。

例子：

如果 Deployment YAML 目前是：

```yaml
spec:
  replicas: 2
```

那 `current = 2`。

### Trace 12：決定擴縮

核心邏輯：

```python
if max_cpu >= SCALE_UP_THRESHOLD:
    ratio = max_cpu / SCALE_UP_THRESHOLD
    desired = math.ceil(current * ratio)
    desired = max(current + 1, desired)
    return desired

elif max_cpu <= SCALE_DOWN_THRESHOLD:
    desired = max(MIN_REPLICAS, current - 1)
    return desired

else:
    return current
```

三種情境：

情境 A：擴容

```text
current = 2
max_cpu = 85
SCALE_UP_THRESHOLD = 70
ratio = 85 / 70 = 1.214
ceil(2 * 1.214) = 3
desired = 3
```

情境 B：縮容

```text
current = 4
max_cpu = 20
SCALE_DOWN_THRESHOLD = 30
desired = current - 1 = 3
```

情境 C：維持

```text
current = 3
max_cpu = 55
30 < max_cpu < 70
desired = 3
```

Scale down 一次只減 1，是一個保守設計。原因是縮容太快可能導致剛縮完又遇到流量上升，造成 thrashing。Scale up 可以快一點，scale down 慢一點，這是 autoscaling 系統常見策略。

### Trace 13：Cooldown 防止抖動

擴縮系統常見問題是 oscillation，也就是在擴容和縮容之間來回震盪。例如 CPU 一下 69%、一下 71%，如果沒有保護機制，系統可能一直改 replicas。

本專案用 cooldown：

```python
if self.last_scale_time:
    elapsed = (datetime.utcnow() - self.last_scale_time).total_seconds()
    remaining = COOLDOWN_SECONDS - elapsed
    if remaining > 0:
        logger.info(f"Cooldown 中，還需等 {remaining:.0f} 秒")
        return False
```

預設 `COOLDOWN_SECONDS=120`。擴縮後 120 秒內不再做下一次擴縮。

例子：

- 10:00:00 scale up from 1 to 3。
- 10:00:45 又預測 CPU 很低。
- 因為只過 45 秒，仍在 cooldown，所以不縮容。
- 10:02:05 再判斷才允許下一次擴縮。

### Trace 14：Patch Kubernetes Deployment

```python
self.apps_v1.patch_namespaced_deployment(
    name=TARGET_DEPLOYMENT,
    namespace=TARGET_NAMESPACE,
    body={"spec": {"replicas": desired}},
)
```

這是最終擴縮的落點。Kubernetes API server 收到 patch 後，Deployment controller 會讓 ReplicaSet 調整 Pod 數量。

這裡不是直接建立 Pod，也不是刪除 Pod。正確方式是調整 Deployment 的 desired state，讓 Kubernetes 自己收斂。

## Prediction Service API 設計

### `/health`

回傳：

```json
{
  "status": "healthy",
  "model_trained": true,
  "last_training": "2026-05-11T...",
  "data_points": 120,
  "timestamp": "2026-05-11T..."
}
```

它不只是 liveness check，也提供模型狀態。這對 debug 很重要：

- `model_trained=false`：代表模型還沒準備好。
- `data_points=0` 或很小：代表 Prometheus 資料不足。
- `last_training=null`：代表尚未成功訓練。

### `/predict`

回傳未來 N 分鐘預測。簡化範例：

```json
{
  "predictions": [
    {
      "timestamp": "2026-05-11T10:01:00",
      "predicted_cpu": 45.3,
      "lower_bound": 35.1,
      "upper_bound": 58.7
    }
  ],
  "max_predicted_cpu": 76.2,
  "avg_predicted_cpu": 51.8,
  "prediction_time": "2026-05-11T10:00:00",
  "minutes_ahead": 30,
  "model_trained_at": "2026-05-11T09:58:00"
}
```

`max_predicted_cpu` 是 controller 的主要決策依據。若要更保守，可以改用 `upper_bound` 的最大值；若要更平滑，可以使用 P95 或 moving average。

### `/train`

手動觸發模型重訓：

```python
background_tasks.add_task(_train)
```

FastAPI 的 `BackgroundTasks` 讓 API 可以立刻回應，不必等待訓練完成。這適合手動 debug 或 demo。

### `/metrics/current`

即時查目前 CPU，使用 Prometheus `/api/v1/query`：

```python
response = await client.get(
    f"{self.prometheus_url}/api/v1/query",
    params={"query": query},
)
```

這和訓練資料使用的 `query_range` 不同，因為它只需要當下值。

## Kubernetes 部署設計深入探討

### Namespace 切分

本專案建立兩個主要 namespace：

- `demo`：放被擴縮的目標服務 `demo-app`。
- `smart-scaler`：放 Prediction Service 與 scaler-controller。

監控元件放在 `monitoring` namespace，由 Helm 安裝 kube-prometheus-stack 時建立。

切 namespace 的好處：

- 權限比較好管理。
- `demo-app` 和 scaler 系統元件可分開觀察。
- 清理時可以刪特定 namespace。

### demo-app Deployment

重要設定：

```yaml
resources:
  requests:
    memory: "64Mi"
    cpu: "100m"
  limits:
    memory: "256Mi"
    cpu: "500m"
```

`requests` 是排程時 Kubernetes 用來估計資源的值。`limits` 是容器可使用的上限。CPU `100m` 代表 0.1 core，`500m` 代表 0.5 core。

readiness probe：

```yaml
readinessProbe:
  httpGet:
    path: /health
    port: 8000
```

readiness probe 決定 Pod 是否可以接流量。若新 Pod 還沒 ready，Service 不應把流量導過去。

liveness probe：

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8000
```

liveness probe 用來判斷容器是否卡死。失敗時 Kubernetes 會重啟容器。

### prediction-service Deployment

Prediction Service 的資源較高：

```yaml
requests:
  memory: "512Mi"
  cpu: "300m"
limits:
  memory: "1Gi"
  cpu: "1000m"
```

原因是 Prophet 訓練模型比普通 API 更吃 CPU 和 Memory。它的 liveness probe initial delay 也較長：

```yaml
initialDelaySeconds: 60
```

這是因為服務啟動時會立刻訓練模型。若 probe 太早開始，Kubernetes 可能誤判服務不健康並重啟，造成 crash loop。

### scaler-controller Deployment

```yaml
replicas: 1
```

這個值很重要。controller 應只跑一個實例，否則兩個 controller 可能同時做決策並 patch Deployment。

例子：

- Controller A 看到 current=1，決定 desired=2。
- Controller B 同時看到 current=1，也決定 desired=2。
- 這個情況還好，但若它們讀取時間不同或 cooldown 狀態不同，可能造成不一致。

正式環境若要 controller 高可用，應實作 leader election，也就是領導者選舉。Kubernetes controller-runtime 中常見這種設計。

### ConfigMap

Prediction Service 的 Prometheus URL 和目標設定放在 ConfigMap：

```yaml
PROMETHEUS_URL: "http://prometheus-kube-prometheus-prometheus.monitoring.svc.cluster.local:9090"
TARGET_NAMESPACE: "demo"
TARGET_DEPLOYMENT: "demo-app"
```

ConfigMap 適合放非敏感設定。若是密碼、token、API key，應使用 Secret。

### ServiceAccount 與 ClusterRoleBinding

scaler-controller Pod 使用：

```yaml
serviceAccountName: smart-scaler-sa
```

再透過 ClusterRoleBinding 綁定到 ClusterRole。這讓 Pod 裡的 Kubernetes client 呼叫 `load_incluster_config()` 時，能使用該 ServiceAccount token 呼叫 API server。

## Docker 與本機開發

### Dockerfile 設計

`prediction-service/Dockerfile` 使用 multi-stage build：

```dockerfile
FROM python:3.11-slim AS builder
...
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim
COPY --from=builder /usr/local /usr/local
```

這個做法把依賴先在 builder stage 安裝，再複製到 runtime image。對 Prophet 這類需要編譯相關依賴的套件，builder stage 可以把建置工具和 runtime 分開。

三個服務都建立非 root 使用者：

```dockerfile
RUN addgroup --system appgroup && adduser --system --ingroup appgroup appuser
USER appuser
```

這是 container security best practice。即使應用被入侵，攻擊者也不會直接拿到 root 權限。

### Docker Compose

Compose 模式包含：

- demo-app
- prediction-service
- prometheus
- grafana

這條路徑適合：

- 快速測 API。
- 看 Prometheus scrape 是否正常。
- 看 Grafana 是否可連線。

但 Compose 模式沒有 Kubernetes API，所以不能測真正的 Deployment patch。真正 autoscaling 行為需要 kind/Kubernetes 模式。

## CI/CD 深入說明

`.github/workflows/ci-cd.yml` 有三個 job：

1. `test`
2. `build-and-push`
3. `deploy`

### test job

使用 Python 3.11，安裝 `prediction-service/requirements.txt`，再跑：

```bash
python -m pytest tests/ -v --tb=short
```

目前測試集中在 `CPUPredictor`，確保模型訓練和預測基本行為正確。

### build-and-push job

使用 matrix 建立三個 image：

```yaml
matrix:
  include:
    - service: prediction
      context: ./prediction-service
      image: k8s-smart-scaler-prediction
    - service: controller
      context: ./scaler-controller
      image: k8s-smart-scaler-controller
    - service: demo
      context: ./demo-app
      image: k8s-smart-scaler-demo
```

matrix 的好處是避免寫三段幾乎一樣的 build steps。

tag 策略：

```yaml
tags: |
  type=sha,prefix=sha-
  type=raw,value=latest,enable=true
```

每次 main branch build 會產生：

- `latest`
- `sha-xxxxxxx`

`sha` tag 比 `latest` 更適合部署，因為它可追蹤到特定 commit。

### deploy job

目前：

```yaml
if: false
```

代表部署 job 被明確關閉。若要正式啟用，需要：

- 設定 `KUBE_CONFIG` secret。
- 將 `if: false` 改成合適條件。
- 確保 manifests image tag 和 registry 正確。

## 測試策略

目前測試檔案是：

```text
prediction-service/tests/test_predictor.py
```

已測項目：

- 初始狀態 `is_trained=False`。
- 資料不足時 `train()` 回傳 False。
- 足夠資料時 `train()` 成功。
- 未訓練時 `predict()` 回傳 None。
- 預測結果包含必要欄位。
- 預測 CPU 在 0 到 100 範圍內。
- 不同 horizon 會回傳對應數量的預測點。

測試資料產生方式：

```python
base = 20 + 30 * math.sin((hour - 6) * math.pi / 12)
cpu = max(5.0, min(95.0, base + random.gauss(0, 3)))
```

這建立帶有週期性和噪聲的 CPU 序列，適合測 Prophet 的基本行為。

可以加強的測試：

- `PrometheusCollector` 的 Prometheus API mock。
- `SmartScaler.decide_replicas()` 的各種門檻測試。
- `scale_to()` cooldown 行為測試。
- `/predict` API integration test。
- Kubernetes client mock，驗證 patch body。

## 演算法與決策策略評估

### 使用 max predicted CPU 的優點與缺點

優點：

- 保守，能提前處理預測視窗中的尖峰。
- 實作簡單，容易解釋。
- 對 demo 很直觀。

缺點：

- 對單一高估點敏感。
- 若 Prophet 上界有抖動，可能過度擴容。
- 沒有考慮高 CPU 持續多久。

更穩健的替代策略：

- 使用未來 30 分鐘的 P90 CPU。
- 要求 CPU 超過門檻持續至少 N 個點。
- 使用 `upper_bound` 做保守擴容，但加上冷卻與持續性條件。
- 引入成本函數，例如 replica cost 與 latency risk 的 trade-off。

### Scale up 快、scale down 慢

本專案 scale up 使用比例擴容，scale down 一次只減 1。這是合理策略。

原因：

- 擴容太慢會造成服務壓力過高。
- 縮容太快會導致剛回收資源又馬上需要擴容。
- Kubernetes Pod 啟動需要時間，因此寧可提前保守擴容。

### 門檻值設計

目前：

```text
SCALE_UP_THRESHOLD = 70
SCALE_DOWN_THRESHOLD = 30
```

這形成 hysteresis，也就是遲滯區間。30 到 70 之間不動作，可以避免頻繁震盪。

如果 scale up 和 scale down 都用 70，例如高於 70 擴、低於 70 縮，就會很容易在 69 到 71 間來回震盪。

## 專題深入一：Prometheus 收集與查詢

本專案的 Prometheus 流程可以拆成四層：

```text
Application instrumentation
  -> scrape target discovery
  -> time series storage
  -> PromQL query/query_range
```

中文對照：

- Application instrumentation / 應用程式指標插裝：讓應用程式暴露 `/metrics`。
- Scrape / 抓取：Prometheus 定期對目標 HTTP endpoint 發 request。
- Time series / 時間序列：同一個 metric name 加上一組 labels 形成一條序列。
- Label / 標籤：例如 `namespace="demo"`、`pod="demo-app-xxxxx"`。
- Sample / 樣本：某個時間點的一個數值。
- PromQL / Prometheus Query Language：Prometheus 的查詢語言。

### Metrics 型別

Prometheus 常見 metrics type 有四種：

| 型別 | 英文 | 特性 | 例子 |
| --- | --- | --- | --- |
| Counter | Counter / 計數器 | 只增不減，重啟歸零 | HTTP request total、CPU seconds total |
| Gauge | Gauge / 儀表值 | 可增可減 | Memory usage、queue length |
| Histogram | Histogram / 直方圖 | 分桶統計，常用於 latency | request duration bucket |
| Summary | Summary / 摘要 | client-side 分位數 | request latency quantile |

本專案查 CPU 的 `container_cpu_usage_seconds_total` 是 Counter。它代表 container 從啟動以來累積使用 CPU 的秒數，所以不能直接拿目前值當 CPU 使用率。

錯誤理解：

```promql
container_cpu_usage_seconds_total
```

這只會看到一個累積值。例如從 1000 變成 1005，表示這段期間又累積了 5 CPU seconds，但單看 1005 沒有意義。

正確做法：

```promql
rate(container_cpu_usage_seconds_total[5m])
```

`rate()` 會估算過去 5 分鐘每秒增加多少。若結果是 `0.25`，可以理解為平均使用 0.25 CPU core。

本專案再乘以 100：

```promql
rate(container_cpu_usage_seconds_total[5m]) * 100
```

因此 `0.25 core` 會表示成 `25`。這裡的百分比是相對於一個 CPU core 的簡化表示。如果 container limit 是 500m，也就是 0.5 core，則 `25` 代表約 0.25 core，約為 limit 的 50%。這點在正式環境要特別注意：CPU percentage 的分母到底是一個 core、request、limit，或所有 replicas 平均值，會影響擴縮門檻。

### Scrape interval 與 step 的差異

Scrape interval / 抓取間隔，是 Prometheus 多久抓一次 target。Docker Compose 中：

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
```

意思是 Prometheus 每 15 秒抓一次 `/metrics`。

Query step / 查詢步長，是 query_range 回傳資料時每隔多久取一點。本專案：

```python
params = {
    "query": query,
    "start": start_time.timestamp(),
    "end": end_time.timestamp(),
    "step": "60",
}
```

意思是即使 Prometheus 每 15 秒收一筆，Prediction Service 查訓練資料時每 60 秒取一個點。

兩者不要混淆：

- `scrape_interval=15s`：Prometheus 儲存資料的頻率。
- `step=60`：Prediction Service 查資料時回傳資料的解析度。

例子：

```text
lookback_hours = 3
step = 60 seconds
expected points = 3 * 60 = 180
```

如果 step 改成 15 秒，資料點約變成 720 筆，模型訓練會更細，但也更耗資源。如果 step 改成 300 秒，只有 36 筆，模型可能看不清短期尖峰。

### query 與 query_range 的實務差異

Prometheus HTTP API 有兩個常用端點：

```text
/api/v1/query
/api/v1/query_range
```

`query` 是 instant query / 即時查詢，用於「現在 CPU 多少」：

```python
response = await client.get(
    f"{self.prometheus_url}/api/v1/query",
    params={"query": query},
)
```

本專案在 `/metrics/current` 使用它。

`query_range` 是 range query / 範圍查詢，用於「過去三小時每分鐘 CPU 是多少」：

```python
response = await client.get(
    f"{self.prometheus_url}/api/v1/query_range",
    params=params,
)
```

本專案在 `fetch_metrics()` 使用它，因為 Prophet 需要歷史序列。

### Label selector 與 regex selector

本專案 PromQL：

```promql
pod=~"demo-app-.*"
```

`=~` 是 regex match / 正規表示式匹配。Deployment 建出的 Pod 名稱會像：

```text
demo-app-7f9c8f6d9b-abcd1
demo-app-7f9c8f6d9b-efgh2
```

因此使用 `demo-app-.*` 可以抓到所有 demo-app replicas。

常見 selector：

| 語法 | 英文 | 說明 |
| --- | --- | --- |
| `label="value"` | exact match | label 必須等於 value |
| `label!="value"` | negative match | label 不等於 value |
| `label=~"regex"` | regex match | label 符合 regex |
| `label!~"regex"` | negative regex match | label 不符合 regex |

本專案也使用：

```promql
container!="POD", container!=""
```

這是為了排除 pause container 和無效 container name。若不排除，可能會把 Kubernetes 基礎設施 container 的資料混進目標 workload。

### 為什麼用 avg 而不是 sum

本專案：

```promql
avg(rate(...)) * 100
```

`avg` 代表多個 Pod 的平均 CPU。這適合回答：「目前每個 Pod 平均壓力如何？」

如果使用：

```promql
sum(rate(...)) * 100
```

代表所有 Pod 總 CPU。這適合回答：「整個 Deployment 總共吃多少 CPU？」

對 autoscaling 來說，兩者含義不同。

例子：

```text
replicas = 2
pod A CPU = 80
pod B CPU = 20
avg = 50
sum = 100
```

如果用 avg，會覺得平均壓力還好；如果用 max，會發現 pod A 很熱；如果用 sum，會看出總需求相當於一個 core。

本專案使用 avg 是簡化設計。正式系統可考慮：

```promql
max(rate(...)) * 100
```

或：

```promql
quantile(0.95, rate(...)) * 100
```

這能避免單一 Pod 過熱被平均值掩蓋。

### Prometheus Trace：一筆 CPU 資料如何進入模型

完整 trace：

```text
1. 使用者呼叫 demo-app /work
2. demo-app container 使用 CPU
3. Kubernetes/cAdvisor 產生 container_cpu_usage_seconds_total
4. Prometheus scrape Kubernetes/cAdvisor 指標
5. Prediction Service 呼叫 /api/v1/query_range
6. Prometheus 回傳 values: [[timestamp, value], ...]
7. metrics_collector.py 轉成 {"timestamp": ts, "cpu_usage": cpu}
8. predictor.py 轉成 Prophet 需要的 ds/y DataFrame
```

對應程式：

```python
for value in results[0]["values"]:
    ts = datetime.fromtimestamp(float(value[0]))
    cpu = float(value[1])
    metrics.append({"timestamp": ts, "cpu_usage": round(cpu, 4)})
```

這裡非常重要：Prometheus 回來的 value 是字串，例如 `"0.1234"`，所以必須 `float(value[1])`。timestamp 是 Unix timestamp，也要轉成 Python datetime。

## 專題深入二：Prophet 預測模型

Prophet 是 additive model / 加法模型的一種實作，但也支援 multiplicative seasonality / 乘法季節性。它通常把時間序列拆成幾個部分：

```text
y(t) = trend(t) + seasonality(t) + holiday(t) + error(t)
```

若使用 multiplicative seasonality，概念會變成季節性效果和趨勢大小有比例關係。

本專案 CPU 預測不使用 holiday，但使用 trend 和 daily/weekly seasonality。

### Prophet 的 ds 與 y

Prophet 強制要求輸入欄位：

```text
ds = datestamp / timestamp
y = target value
```

本專案資料原本是：

```python
{"timestamp": datetime(...), "cpu_usage": 42.5}
```

轉換成：

```python
df = df.rename(columns={"timestamp": "ds", "cpu_usage": "y"})
```

如果沒有轉成 `ds` 和 `y`，Prophet 會無法 fit。這是 Prophet API 的硬性規則。

### 訓練資料量與時間解析度

`CPUPredictor.train()` 要求至少 15 筆資料：

```python
if len(metrics_data) < 15:
    return False
```

這是最低防線。若每分鐘一筆，15 筆只代表 15 分鐘，足以跑 demo，但不足以學到 daily seasonality。因為 daily seasonality 至少要看到跨小時甚至跨天的資料才更有意義。

實務建議：

| 預測目標 | 建議資料量 |
| --- | --- |
| 未來 5 到 15 分鐘 CPU | 至少數小時 |
| 未來 30 到 60 分鐘 CPU | 至少 1 到 3 天 |
| 每日週期預測 | 至少 7 到 14 天 |
| 每週週期預測 | 至少 4 週以上 |

本專案的 `lookback_hours=3` 是 demo 取向。若要讓 `weekly_seasonality=True` 真正發揮作用，需要更長資料。

### 3-sigma outlier filtering 的限制

本專案使用：

```python
mean_y = df["y"].mean()
std_y = df["y"].std()
df = df[(df["y"] >= mean_y - 3 * std_y) & (df["y"] <= mean_y + 3 * std_y)]
```

這是簡單有效的 outlier filter，但有兩個限制：

1. 如果資料不是常態分布，3-sigma 不一定合理。
2. 如果真實尖峰就是系統需要預測的重點，移除尖峰可能讓模型低估風險。

例子：

```text
CPU 平常 10%，每天 12:00 會真實衝到 90%。
```

如果 90% 被當成 outlier 移除，模型就學不到中午尖峰。正式系統應區分：

- data error / 資料錯誤，例如 9999% CPU。
- business spike / 真實業務尖峰，例如促銷造成 90% CPU。

更細緻做法：

- 只 clip 明顯不可能值，例如 `<0` 或 `>100`。
- 使用 rolling median / 滾動中位數。
- 使用 Hampel filter。
- 保留尖峰但加上事件特徵，例如 campaign、batch job schedule。

### Prophet 參數深入

本專案：

```python
Prophet(
    changepoint_prior_scale=0.05,
    seasonality_mode="multiplicative",
    daily_seasonality=True,
    weekly_seasonality=True,
    interval_width=0.95,
    uncertainty_samples=200,
)
```

`changepoint_prior_scale` / 變化點先驗尺度：

- 小：趨勢比較平滑，不容易跟著尖峰跑。
- 大：趨勢比較靈敏，容易捕捉變化，但可能 overfit。

例子：

```text
如果 CPU 因新版部署後永久從 20% 變成 50%，需要模型能捕捉 changepoint。
如果 CPU 只是短暫尖峰，太大的 changepoint_prior_scale 可能把尖峰當成新趨勢。
```

`seasonality_mode` / 季節性模式：

- `additive`：季節性加固定量。例如每天中午都增加 10% CPU。
- `multiplicative`：季節性依基準比例增加。例如基準越高，中午尖峰越大。

CPU workload 常常更像 multiplicative，因為低流量時尖峰有限，高流量時尖峰幅度更大。

`interval_width=0.95` / 預測區間：

預測不只是一個點，還有不確定性範圍：

```text
yhat_lower <= yhat <= yhat_upper
```

本專案回傳：

```python
"lower_bound": row["yhat_lower"]
"upper_bound": row["yhat_upper"]
```

若要保守擴容，可以用 `upper_bound`。例如：

```text
predicted_cpu = 65
upper_bound = 82
scale_up_threshold = 70
```

用 predicted_cpu 不擴容；用 upper_bound 會擴容。這代表「雖然最可能是 65%，但有顯著風險超過 70%。」

### 預測視窗 horizon

`minutes_ahead` 是 prediction horizon / 預測視窗：

```python
future_dates = [now + timedelta(minutes=i) for i in range(1, minutes_ahead + 1)]
```

若 `minutes_ahead=30`，系統預測未來 30 個一分鐘點。

horizon 越長：

- 可以更早擴容。
- 不確定性通常越高。
- 對模型品質要求越高。

horizon 越短：

- 預測較可靠。
- 但可能來不及啟動 Pod。

選擇 horizon 應考慮 Pod startup time：

```text
image pull 20s
container start 5s
readiness 10s
安全緩衝 30s
至少要提前約 65s 預測到壓力
```

如果應用冷啟動需要 3 分鐘，`LOOKAHEAD_MINUTES=1` 就太短。

### Prophet Trace：一次 /predict 如何產生結果

完整 trace：

```text
1. scaler-controller GET /predict?minutes_ahead=30
2. FastAPI handler 檢查 predictor.is_trained
3. 若未訓練，PrometheusCollector.fetch_metrics(lookback_hours=3)
4. CPUPredictor.train(metrics)
5. CPUPredictor.predict(30)
6. 建立未來 30 個 timestamp
7. Prophet model.predict(future_df)
8. 讀取 yhat/yhat_lower/yhat_upper
9. 計算 max_predicted_cpu 與 avg_predicted_cpu
10. 回傳 JSON 給 controller
```

對應程式重點：

```python
forecast = self.model.predict(future_df)
```

以及：

```python
max_cpu = max(p["predicted_cpu"] for p in predictions)
avg_cpu = sum(p["predicted_cpu"] for p in predictions) / len(predictions)
```

這裡 `max_cpu` 是控制系統的核心訊號。它從一串時間序列被壓縮成單一決策值，這叫 feature aggregation / 特徵聚合。不同聚合方式會導致不同擴縮行為。

## 專題深入三：CI/CD Pipeline

CI/CD 是 Continuous Integration / Continuous Delivery 或 Continuous Deployment 的縮寫。

中文通常翻譯為：

- CI：持續整合。
- CD：持續交付或持續部署。

兩者差異：

- Continuous Delivery / 持續交付：自動完成 build/test/package，但部署到 production 可能需要人工批准。
- Continuous Deployment / 持續部署：通過 pipeline 後自動部署。

本專案的 GitHub Actions 比較接近 CI + image delivery，因為 deploy job 目前 `if: false`，不會真的自動部署。

### Workflow trigger / 觸發條件

```yaml
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
```

意思是：

- push 到 `main` 或 `develop` 時執行。
- 對 `main` 開 Pull Request 時執行。

實務上這樣可以確保：

- develop branch 的變更會跑測試。
- 合併 main 前的 PR 會跑測試。
- main branch 通過後才 build images。

### Job dependency / 工作相依

```yaml
build-and-push:
  needs: test
```

`needs: test` 表示 build-and-push 必須等 test 成功才會執行。這是 pipeline gate / 管線閘門。

如果測試失敗，image 不會被 build/push，避免把壞版本推到 registry。

### Cache / 快取

test job 中：

```yaml
cache: "pip"
cache-dependency-path: prediction-service/requirements.txt
```

這會根據 requirements 檔案快取 pip dependencies。若 requirements 沒變，下次 workflow 可以重用快取，加快安裝速度。

Docker build 中：

```yaml
cache-from: type=gha
cache-to: type=gha,mode=max
```

這使用 GitHub Actions cache 作為 Docker Buildx cache。優點是每次 build 不必從零開始安裝所有 layers。

### Matrix build / 矩陣建置

本專案有三個 image：

- prediction
- controller
- demo

使用 matrix：

```yaml
strategy:
  matrix:
    include:
      - service: prediction
        context: ./prediction-service
        image: k8s-smart-scaler-prediction
      - service: controller
        context: ./scaler-controller
        image: k8s-smart-scaler-controller
      - service: demo
        context: ./demo-app
        image: k8s-smart-scaler-demo
```

這代表同一組 build steps 會對三組參數各跑一次。

如果不用 matrix，會需要複製三份幾乎相同的 YAML，維護成本較高。

### Image tag / 映像標籤策略

本專案 tag：

```yaml
tags: |
  type=sha,prefix=sha-
  type=raw,value=latest,enable=true
```

會產生：

```text
jiachanggit/k8s-smart-scaler-demo:latest
jiachanggit/k8s-smart-scaler-demo:sha-a1b2c3d
```

`latest` 適合人類快速測試，但不適合正式部署，因為它會移動。今天的 latest 和明天的 latest 可能不是同一份程式。

`sha-a1b2c3d` 是 immutable-ish tag / 近似不可變標籤，對應到 commit。正式部署建議使用 sha tag。

例子：

```yaml
image: jiachanggit/k8s-smart-scaler-demo:sha-a1b2c3d
```

當 production 出問題，可以清楚知道目前跑哪個 commit。

### Secret / 機密管理

Docker Hub token：

```yaml
password: ${{ secrets.DOCKERHUB_TOKEN }}
```

這代表 token 不寫在 repo，而是放 GitHub Secrets。這是必要安全實務。

deploy job 中預留：

```yaml
echo "${{ secrets.KUBE_CONFIG }}" | base64 -d > $HOME/.kube/config
```

這表示 Kubernetes kubeconfig 也應放 secret。它的權限非常高，不能 commit 到 Git。

### CI/CD Trace：一次 main push 發生什麼事

```text
1. Developer push commit to main
2. GitHub Actions 觸發 workflow
3. test job checkout code
4. setup Python 3.11
5. install prediction-service dependencies
6. run pytest
7. 若 test 成功，build-and-push job 啟動
8. matrix 分成 prediction/controller/demo 三組 build
9. login Docker Hub
10. docker/metadata-action 產生 latest 與 sha tags
11. docker/build-push-action build image 並 push
12. deploy job 因 if: false 被跳過
```

若要啟用真正 CD，可以把：

```yaml
if: false
```

改成：

```yaml
if: github.ref == 'refs/heads/main'
```

但啟用前要先確認：

- `KUBE_CONFIG` secret 已設定。
- kubeconfig 權限最小化。
- Deployment manifests 使用 sha tag。
- 有 rollback 流程。
- 有環境分層，例如 staging 和 production。

### Deployment strategy / 部署策略

目前 deploy job 是直接 `kubectl apply`：

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/rbac/
kubectl apply -f k8s/prediction-service/
kubectl apply -f k8s/scaler-controller/
kubectl apply -f k8s/demo-app/
```

這是 declarative apply / 宣告式套用。Kubernetes 會比較目前狀態與 YAML 期望狀態，再更新差異。

若要更成熟，可以考慮：

- Kustomize：不同環境有不同 patch。
- Helm chart：封裝 values。
- GitOps：Argo CD 或 Flux 監看 Git repo，自動同步 cluster。
- Progressive delivery：Argo Rollouts 做 canary 或 blue-green。

## 專題深入四：HPA 與本專案自製 Scaler 對照

HPA 全名是 Horizontal Pod Autoscaler，中文可稱水平 Pod 自動擴縮器。它是 Kubernetes 原生 autoscaling controller，會根據 metrics 自動調整 Deployment、ReplicaSet 或 StatefulSet 的 replicas。

### HPA 基本概念

Horizontal / 水平，代表增加或減少 Pod 數量。

Vertical / 垂直，代表增加或減少單個 Pod 的 CPU/Memory request 或 limit。Kubernetes 也有 VPA，Vertical Pod Autoscaler。

本專案做的是 horizontal scaling，因為它調整 replicas。

HPA 的典型流程：

```text
Metrics Server 或 Custom Metrics API
  -> HPA controller 讀取 metrics
  -> 計算 desired replicas
  -> 更新 scale subresource
  -> Deployment 調整 Pod 數量
```

本專案流程：

```text
Prometheus
  -> Prediction Service 預測未來 CPU
  -> scaler-controller 計算 desired replicas
  -> patch Deployment
  -> Deployment 調整 Pod 數量
```

相同點：

- 都是調整 replicas。
- 都是水平擴縮。
- 都透過 Kubernetes API 修改期望副本數。

不同點：

| 面向 | HPA | 本專案 Smart Scaler |
| --- | --- | --- |
| 資料 | 當下或近期 metrics | Prometheus 歷史資料 + 未來預測 |
| 決策 | Kubernetes HPA controller | 自製 Python controller |
| 模型 | 固定演算法 | Prophet forecast + 自訂策略 |
| 資料來源 | Metrics Server / Custom Metrics API | Prometheus HTTP API |
| 反應型態 | Reactive | Predictive |
| 生產成熟度 | Kubernetes 原生，成熟 | 原型，需補強 |

### HPA 的 desired replicas 公式

HPA 對 resource metrics 常用公式概念是：

```text
desiredReplicas = ceil(currentReplicas * currentMetricValue / desiredMetricValue)
```

例子：

```text
currentReplicas = 2
current CPU utilization = 90%
target CPU utilization = 60%
desiredReplicas = ceil(2 * 90 / 60) = 3
```

可以看到，本專案 scale up 邏輯非常類似：

```python
ratio = max_cpu / SCALE_UP_THRESHOLD
desired = math.ceil(current * ratio)
```

差異在於 HPA 使用 current CPU，本專案使用 predicted max CPU。

換句話說，本專案可以視為：

```text
HPA formula with forecasted metric
```

也就是「把即時指標換成預測指標」。

### HPA YAML 範例

如果使用原生 HPA，可能會寫：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: demo-app-hpa
  namespace: demo
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: demo-app
  minReplicas: 1
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

這代表：

- 目標是 `demo-app` Deployment。
- replicas 在 1 到 10。
- 目標 CPU average utilization 是 70%。

HPA 需要 Metrics Server 提供 CPU/memory resource metrics。如果要使用 Prometheus metrics，通常需要 Prometheus Adapter 將 Prometheus query 暴露成 Kubernetes Custom Metrics API 或 External Metrics API。

### Metrics Server、Custom Metrics API、External Metrics API

關鍵字：

- Metrics Server / 指標伺服器：提供 CPU、Memory resource metrics。
- Custom Metrics API / 自訂指標 API：提供 Kubernetes 物件相關自訂指標，例如每個 Pod 的 request per second。
- External Metrics API / 外部指標 API：提供非 Kubernetes 物件指標，例如 queue length、cloud load balancer requests。
- Prometheus Adapter / Prometheus 轉接器：把 Prometheus metrics 轉成 Kubernetes autoscaling API 可讀格式。

HPA 如果要用 Prometheus 的資料，常見架構是：

```text
Prometheus
  -> Prometheus Adapter
  -> Custom Metrics API
  -> HPA
  -> Deployment replicas
```

本專案沒有走 Custom Metrics API，而是：

```text
Prometheus
  -> prediction-service
  -> scaler-controller
  -> Deployment replicas
```

這樣比較容易教學和客製化，但少了 HPA 原生的穩定化策略。

### Stabilization window / 穩定視窗

HPA 有 stabilization window 概念，用於避免頻繁擴縮。簡單說，它會在一段時間內保留建議值，尤其是 scale down 時會更保守。

本專案對應概念是：

```python
COOLDOWN_SECONDS = 120
```

Cooldown 是最簡化的穩定策略。它和 stabilization window 的差異：

- Cooldown：擴縮後固定一段時間不做任何動作。
- Stabilization window：在時間窗口內選擇較安全的 desired replicas，例如 scale down 時取過去一段時間建議值的最大值。

例子：

```text
過去 5 分鐘建議 replicas: 5, 4, 3, 2
scale down stabilization 可以選 5，避免太快縮到 2。
```

本專案若要改進，可以保存最近 N 次 desired replicas：

```python
recent_recommendations = [5, 4, 3, 2]
scale_down_desired = max(recent_recommendations)
```

### HPA 與 predictive scaling 如何整合

有三種可行設計：

設計一：本專案目前做法，自製 controller 直接 patch Deployment。

優點：

- 最容易理解。
- 完全掌控預測與決策。
- 不需要 Prometheus Adapter。

缺點：

- 要自己實作 cooldown、stabilization、leader election、事件與衝突處理。

設計二：Prediction Service 輸出 custom metric，交給 HPA。

流程：

```text
Prediction Service
  -> predicted_cpu metric
  -> Prometheus
  -> Prometheus Adapter
  -> HPA
  -> Deployment
```

優點：

- 使用 HPA 原生擴縮機制。
- 可利用 HPA behavior policies。

缺點：

- Prometheus Adapter 設定較複雜。
- 預測值轉成 HPA 可理解的 metric 需要額外設計。

設計三：HPA 做保底，Smart Scaler 做提前擴容。

流程：

```text
HPA handles current CPU pressure
Smart Scaler handles predicted future pressure
```

這種設計要小心兩個 controller 同時寫 replicas。正式做法通常要定義清楚 ownership，例如：

- HPA 管理 Deployment replicas。
- Smart Scaler 不直接 patch Deployment，而是改 HPA minReplicas。

例子：

```text
平常 HPA minReplicas = 1
Smart Scaler 預測 30 分鐘後 CPU 高峰
Smart Scaler 暫時把 HPA minReplicas 提高到 4
高峰過後再降回 1
```

這樣 HPA 仍是 replicas 的主要控制者，Smart Scaler 只調整保底容量。

### 本專案和 HPA 的實作對照 Trace

HPA trace：

```text
1. Metrics Server 收集 Pod CPU
2. HPA controller 讀取 metrics
3. HPA 計算 desired replicas
4. HPA 更新 scale subresource
5. Deployment controller 建立或刪除 Pod
```

本專案 trace：

```text
1. Prometheus 收集 CPU
2. Prediction Service 查 query_range
3. Prophet 預測未來 CPU
4. scaler-controller 計算 desired replicas
5. scaler-controller patch Deployment spec.replicas
6. Deployment controller 建立或刪除 Pod
```

兩者最後都回到 Deployment controller。差異在前半段：HPA 讀現在，本專案讀歷史並預測未來。

## 可觀測性 Observability

Observability 通常包含三大支柱：

- Metrics / 指標
- Logs / 日誌
- Traces / 分散式追蹤

本專案主要實作 metrics 和 logs。

### Metrics

demo-app 透過 `prometheus-fastapi-instrumentator` 暴露 HTTP metrics。

Prometheus 也收集 Kubernetes container CPU metrics。

### Logs

Prediction Service 記錄：

- 啟動與關閉。
- 背景重訓。
- Prometheus 查詢成功或 fallback。
- 模型訓練成功或失敗。

scaler-controller 記錄：

- 啟動設定。
- 預測結果。
- 擴容或縮容決策。
- cooldown 狀態。
- Kubernetes API 錯誤。

### Traces

目前沒有 OpenTelemetry distributed tracing。若要追蹤跨服務流程，可以加入：

- OpenTelemetry SDK
- Trace ID propagation
- Jaeger 或 Tempo

可 trace 的 span 例子：

- `demo-app /work`
- `prediction-service fetch Prometheus`
- `prediction-service train Prophet`
- `prediction-service predict`
- `scaler-controller fetch_prediction`
- `scaler-controller patch_deployment`

這樣可以從一次擴縮決策回溯到 Prometheus 查詢耗時、模型預測耗時與 Kubernetes API latency。

## 安全性與風險

### 權限範圍

目前 controller 使用 ClusterRole，權限可跨 namespace 讀寫 Deployment。若正式環境只需要操作 `demo` namespace，建議改成 namespaced Role + RoleBinding，降低 blast radius。

### Synthetic data 風險

Prometheus 不可用時使用合成資料對 demo 很友善，但 production 可能危險。真實系統應：

- 將 Prediction Service 狀態標記為 degraded。
- Controller 在資料來源不可用時停止擴縮。
- 發出 alert。

### 單 controller 實例

目前 replicas 固定 1，避免重複決策。正式環境若要高可用，應導入 leader election。

### 模型共享狀態

Prediction Service 目前單 worker：

```dockerfile
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

這很重要，因為模型放在 process memory 的全域變數：

```python
predictor = CPUPredictor()
collector = PrometheusCollector()
```

如果開多個 workers，每個 worker 會有自己的模型狀態，可能出現某些 request 打到未訓練 worker 的情況。若要多 worker，應將模型狀態外部化或確保每個 worker 都能獨立初始化。

## 目前設計限制

1. CPU 查詢用的是平均值，沒有考慮每個 Pod 的最大值。
2. 沒有真正整合 Kubernetes HPA，只是自製 controller patch replicas。
3. 沒有 leader election。
4. 沒有持久化模型，每次 Prediction Service 重啟都要重新訓練。
5. 沒有模型品質評估，例如 MAE、RMSE、MAPE。
6. 沒有事件記錄到 Kubernetes Event。
7. 沒有處理 forecast uncertainty 對決策的影響。
8. Prometheus fallback synthetic data 適合 demo，但不適合 production 自動決策。
9. `deploy` CI/CD job 目前關閉。

## 建議改進方向

### 改進一：加入模型品質指標

可以在訓練時切分資料：

- 前 80% 當 train。
- 後 20% 當 validation。

計算：

- MAE，Mean Absolute Error，平均絕對誤差。
- RMSE，Root Mean Squared Error，均方根誤差。
- MAPE，Mean Absolute Percentage Error，平均絕對百分比誤差。

若誤差太高，controller 應避免使用該模型做擴縮。

### 改進二：使用上界或風險分數

目前用 `max_predicted_cpu`。可以改為：

```text
risk_score = 0.7 * max_predicted_cpu + 0.3 * max_upper_bound
```

或直接使用 `upper_bound`，讓系統更保守。

### 改進三：引入持續性條件

不要只因為一個點超過 70% 就擴容，可要求：

```text
未來 30 分鐘內至少 5 個點超過 70%
```

這可降低單點預測誤差造成的過度擴容。

### 改進四：導入 Kubernetes Events

每次擴縮時寫 Kubernetes Event：

```text
SmartScaler scaled demo/demo-app from 2 to 3 because predicted CPU max is 85%
```

這會讓 `kubectl describe deployment demo-app -n demo` 更容易 debug。

### 改進五：加入 Leader Election

正式 controller 應支援多 replica + leader election。只有 leader 可以執行 patch，其餘 standby。這樣兼顧高可用與一致性。

### 改進六：與 HPA 整合

另一種架構是不要直接 patch Deployment，而是輸出 custom metric 給 HPA：

```text
prediction-service -> custom metrics API -> HPA -> Deployment replicas
```

這樣可以保留 Kubernetes 原生 HPA 行為，例如 stabilization window、scale policies。

## 結論

K8s Smart Scaler 展示了一個完整的預測式 Kubernetes 擴縮容流程：FastAPI 目標服務產生 CPU 負載，Prometheus 收集時間序列指標，Prediction Service 使用 Prophet 預測未來 CPU，scaler-controller 根據預測結果透過 Kubernetes API patch Deployment replicas。

這個專案的價值不只在於能跑起來，更在於它清楚呈現了 predictive autoscaling 的核心資料流與工程切分：

- 指標收集與查詢：Prometheus + PromQL。
- 時間序列建模：pandas + Prophet。
- 擴縮決策：threshold + proportional scaling + cooldown。
- Kubernetes 操作：Python client + RBAC + Deployment patch。
- 本機可重現環境：Docker Compose + kind + Helm。

若要推向正式環境，建議優先補強模型品質評估、leader election、fallback 安全策略、事件記錄與 HPA/custom metrics 整合。以目前狀態來看，它是一個很好的教學型與原型型系統，能完整示範從監控資料到 Kubernetes 自動化控制的端到端流程。
