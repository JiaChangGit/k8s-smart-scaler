# K8s Smart Scaler

K8s Smart Scaler 是一個以 CPU 趨勢預測驅動 Kubernetes Deployment 擴縮容的範例專案。它不是等到當下 CPU 超過門檻才反應，而是透過 Prometheus 收集歷史指標，再用 Prophet 預測未來一段時間的 CPU 使用率，最後由自製 controller 主動調整目標 Deployment 的 replica 數量。

專案包含三個主要服務：

- `demo-app`：FastAPI 範例服務，提供 `/work` 端點產生可控 CPU 負載，並暴露 `/metrics` 給 Prometheus scrape。
- `prediction-service`：FastAPI 預測服務，從 Prometheus 讀取 `demo-app` CPU 指標，使用 Prophet 訓練模型並提供預測 API。
- `scaler-controller`：輪詢 Prediction Service，依預測的最大 CPU 值決定是否 patch Kubernetes Deployment replicas。

## 架構概覽

```text
load test
   |
   v
demo-app  ---- /metrics ---->  Prometheus
   ^                              |
   |                              v
   |                       prediction-service
   |                        Prophet forecast
   |                              |
   |                         /predict
   |                              v
scaler-controller  ---- patch replicas ----> Kubernetes Deployment
```

預設目標是 `demo` namespace 內的 `demo-app` Deployment。Smart Scaler 元件部署在 `smart-scaler` namespace，監控元件部署在 `monitoring` namespace。

## 功能特色

- 使用 Prometheus 查詢 Kubernetes pod CPU 使用率。
- 使用 Prophet 進行未來 N 分鐘 CPU 趨勢預測。
- 依預測最大 CPU 自動 scale up 或 scale down。
- 支援 cooldown，避免短時間內連續擴縮。
- 提供 Docker Compose 本機體驗環境。
- 提供 kind + Helm + Kubernetes manifests 的本機叢集部署流程。
- 包含 GitHub Actions 測試與 Docker image build/push workflow。

## 專案結構

```text
.
├── demo-app/                  # 可產生 CPU 負載的 FastAPI 範例服務
├── prediction-service/         # Prophet CPU 預測 API
├── scaler-controller/          # Kubernetes 自動擴縮 controller
├── k8s/                        # Namespace、RBAC、Deployment、Service、Monitoring manifests
├── monitoring/                 # Docker Compose 使用的 Prometheus 設定
├── scripts/                    # setup、demo、load test、cleanup、local deploy 腳本
├── .github/workflows/ci-cd.yml # GitHub Actions CI/CD
├── docker-compose.yml          # 本機 Compose 觀察與 API 測試環境
├── kind-config.yaml            # kind cluster 與 NodePort 對應設定
└── README.md
```

## 需求

本機 Docker Compose 模式：

- Docker
- Docker Compose

Kubernetes / kind 模式：

- Docker
- kubectl
- kind
- Helm
- bash
- 可選：`hey` 或 `ab`，用於壓力測試；沒有時腳本會退回使用 `curl`

Python 測試：

- Python 3.11
- pip

## 快速開始：Docker Compose

這條路徑適合快速看服務、API 與 Prometheus/Grafana，不會真的 patch Kubernetes Deployment。

```bash
docker compose up --build
```

啟動後可使用：

| 服務 | URL | 說明 |
| --- | --- | --- |
| Demo App | http://localhost:8001 | 範例服務 |
| Prediction Service | http://localhost:8000 | CPU 預測 API |
| Prometheus | http://localhost:9090 | 指標查詢 |
| Grafana | http://localhost:3000 | 帳號 `admin`，密碼 `admin123` |

常用檢查：

```bash
curl http://localhost:8001/health
curl "http://localhost:8001/work?intensity=80&duration=2"
curl http://localhost:8000/health
curl "http://localhost:8000/predict?minutes_ahead=30"
curl http://localhost:8000/metrics/current
```

停止 Compose：

```bash
docker compose down
```

若也要刪除 Prometheus/Grafana volume：

```bash
docker compose down -v
```

## Kubernetes 本機部署：kind

`scripts/setup.sh` 會建立 kind cluster、安裝 kube-prometheus-stack、建立 image、載入 image 到 kind，並套用 Kubernetes manifests。

```bash
bash scripts/setup.sh <dockerhub-username>
```

預設 cluster 名稱是 `smart-scaler`，`kind-config.yaml` 會把 host port `30080` 對應到 cluster 內的 demo-app NodePort。

部署完成後：

```bash
kubectl get pods -n smart-scaler
kubectl get pods -n demo
kubectl get svc -n smart-scaler
kubectl get svc -n demo
```

服務存取：

```bash
# Demo App
curl http://localhost:30080/health

# Prediction Service
kubectl port-forward svc/prediction-service 8000:8000 -n smart-scaler
curl http://localhost:8000/health
curl "http://localhost:8000/predict?minutes_ahead=30"

# Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090 -n monitoring

# Grafana
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```

Grafana 預設帳密：

```text
admin / admin123
```

> 注意：目前 Kubernetes manifests 中的 image 預設為 `jiachanggit/k8s-smart-scaler-*:latest`，且 `imagePullPolicy` 為 `Never`，適合 kind 先用 `kind load docker-image` 載入本機 image。若要使用自己的 Docker Hub 或 registry，請同步更新 `k8s/demo-app/deployment.yaml`、`k8s/prediction-service/deployment.yaml`、`k8s/scaler-controller/deployment.yaml` 的 image 名稱。

## Demo 與壓力測試

產生 CPU 負載：

```bash
bash scripts/load-test.sh
```

也可以指定目標、時間、併發數與強度：

```bash
bash scripts/load-test.sh http://localhost:30080 120 15 85
```

參數順序：

1. Demo App URL，預設 `http://localhost:30080`
2. 測試秒數，預設 `120`
3. 併發數，預設 `15`
4. CPU 強度，預設 `85`

執行完整展示流程：

```bash
bash scripts/demo.sh
```

觀察擴縮：

```bash
kubectl get pods -n demo -w
kubectl logs -n smart-scaler deployment/scaler-controller -f
kubectl logs -n smart-scaler deployment/prediction-service -f
```

## API

### Demo App

| Method | Path | 說明 |
| --- | --- | --- |
| GET | `/` | 回傳 app、pod、version |
| GET | `/health` | 健康檢查 |
| GET | `/work?intensity=50&duration=1.0` | 產生 CPU 負載 |
| GET | `/metrics` | Prometheus metrics |

`/work` 參數：

- `intensity`：CPU 強度，會限制在 `1` 到 `100`。
- `duration`：負載持續秒數。

### Prediction Service

| Method | Path | 說明 |
| --- | --- | --- |
| GET | `/health` | 健康檢查與模型狀態 |
| GET | `/predict?minutes_ahead=30` | 預測未來 N 分鐘 CPU |
| POST | `/train` | 背景觸發模型重訓 |
| GET | `/metrics/current` | 查詢目前 CPU 使用率 |

`/predict` 回傳欄位包含：

- `predictions`：每分鐘預測點，含 `predicted_cpu`、`lower_bound`、`upper_bound`。
- `max_predicted_cpu`：預測期間最大 CPU。
- `avg_predicted_cpu`：預測期間平均 CPU。
- `prediction_time`：預測產生時間。
- `minutes_ahead`：預測長度。
- `model_trained_at`：模型最近訓練時間。

## 擴縮邏輯

`scaler-controller` 每隔 `CHECK_INTERVAL` 秒呼叫 Prediction Service：

1. 讀取未來 `LOOKAHEAD_MINUTES` 分鐘預測。
2. 取得 `max_predicted_cpu`。
3. 若高於 `SCALE_UP_THRESHOLD`，依比例增加 replicas，且至少增加 1。
4. 若低於 `SCALE_DOWN_THRESHOLD`，replicas 減少 1。
5. replicas 會被限制在 `MIN_REPLICAS` 到 `MAX_REPLICAS`。
6. 每次擴縮後會進入 `COOLDOWN_SECONDS`，避免連續操作。

預設設定：

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `PREDICTION_SERVICE_URL` | `http://prediction-service:8000` | Prediction Service URL |
| `TARGET_NAMESPACE` | `demo` | 目標 Deployment namespace |
| `TARGET_DEPLOYMENT` | `demo-app` | 目標 Deployment 名稱 |
| `SCALE_UP_THRESHOLD` | `70.0` | 預測 CPU 高於此值時擴容 |
| `SCALE_DOWN_THRESHOLD` | `30.0` | 預測 CPU 低於此值時縮容 |
| `MIN_REPLICAS` | `1` | 最小 replicas |
| `MAX_REPLICAS` | `10` | 最大 replicas |
| `CHECK_INTERVAL` | `60` | controller 檢查間隔秒數 |
| `LOOKAHEAD_MINUTES` | `30` | 預測視窗分鐘數 |
| `COOLDOWN_SECONDS` | `120` | 擴縮 cooldown 秒數 |

Prediction Service 設定：

| 變數 | 預設值 | 說明 |
| --- | --- | --- |
| `PROMETHEUS_URL` | `http://prometheus:9090` | Prometheus URL |
| `TARGET_NAMESPACE` | `demo` | PromQL 查詢 namespace |
| `TARGET_DEPLOYMENT` | `demo-app` | PromQL 查詢 deployment/pod 名稱前綴 |
| `LOG_LEVEL` | `INFO` | 日誌等級 |

如果 Prometheus 查不到資料，Prediction Service 會產生合成 CPU 資料，方便 demo 或開發時仍可訓練與回傳預測結果。

## 監控

Docker Compose 模式使用 `monitoring/prometheus.yml`：

- scrape Prometheus 自身
- scrape `demo-app:8000/metrics`
- scrape `prediction-service:8000/metrics`

Kubernetes 模式使用 kube-prometheus-stack，並在 `k8s/monitoring/prometheus-values.yaml` 啟用：

- retention `7d`
- 允許 ServiceMonitor / PodMonitor selector
- 透過 pod annotation scrape `/metrics`

`demo-app` Deployment 已加入：

```yaml
prometheus.io/scrape: "true"
prometheus.io/port: "8000"
prometheus.io/path: "/metrics"
```

## 測試

目前單元測試集中在 `prediction-service` 的 `CPUPredictor`：

```bash
cd prediction-service
pip install -r requirements.txt
pip install pytest pytest-asyncio
python3 -m pytest tests/ -v
```

測試涵蓋：

- 初始狀態
- 資料不足時不訓練
- 訓練成功
- 未訓練時不預測
- 預測資料結構
- CPU 預測值範圍
- 不同預測時間長度

## CI/CD

GitHub Actions workflow 位於 `.github/workflows/ci-cd.yml`。

流程：

1. Push 到 `main` 或 `develop`、或對 `main` 開 PR 時執行測試。
2. `main` branch 測試通過後，build 並 push 三個 Docker images：
   - `k8s-smart-scaler-prediction`
   - `k8s-smart-scaler-controller`
   - `k8s-smart-scaler-demo`
3. deploy job 目前設定為 `if: false`，代表不會自動部署。若要啟用，需設定 Kubernetes kubeconfig secret 並調整 workflow 條件。

需要的 secret：

- `DOCKERHUB_TOKEN`：Docker Hub 登入 token。
- `KUBE_CONFIG`：base64 編碼後的 kubeconfig；只有啟用 deploy job 時需要。

## 清理

互動式清理：

```bash
bash scripts/cleanup.sh
```

只刪除 Kubernetes 資源，保留 kind cluster 與 Docker image：

```bash
bash scripts/cleanup.sh --soft
```

完整清理：

```bash
bash scripts/cleanup.sh --all
```

清理腳本會處理：

- `kubectl port-forward` process
- `smart-scaler` / `demo` namespace
- RBAC
- Prometheus Helm release
- kind cluster
- smart-scaler Docker images
- Docker Compose containers / volumes

## 常見問題

### Prediction Service 一開始啟動較慢

Prediction Service 啟動時會先從 Prometheus 取資料並訓練 Prophet 模型。Kubernetes manifest 已將 liveness probe 的 `initialDelaySeconds` 設為 60 秒，避免模型初始化期間被過早重啟。

### `/predict` 回傳 503

代表模型尚未訓練完成或訓練失敗。可以查看 logs：

```bash
kubectl logs -n smart-scaler deployment/prediction-service -f
```

也可以手動觸發訓練：

```bash
curl -X POST http://localhost:8000/train
```

### Prometheus 查不到 demo-app 指標

檢查 demo-app pod 是否有 metrics：

```bash
curl http://localhost:30080/metrics
```

檢查 Prometheus 是否可查到 container CPU 指標：

```promql
avg(rate(container_cpu_usage_seconds_total{namespace="demo",pod=~"demo-app-.*",container!="POD",container!=""}[5m])) * 100
```

### kind 內 Pod 顯示 ImagePullBackOff

目前 manifests 使用 `imagePullPolicy: Never`，代表 Kubernetes 會使用已載入 kind node 的本機 image。請確認 image 已載入：

```bash
kind load docker-image jiachanggit/k8s-smart-scaler-demo:latest --name smart-scaler
kind load docker-image jiachanggit/k8s-smart-scaler-prediction:latest --name smart-scaler
kind load docker-image jiachanggit/k8s-smart-scaler-controller:latest --name smart-scaler
```

如果你改用自己的 registry，請同步更新 manifests 的 image 名稱。

### scaler-controller 沒有調整 replicas

請確認：

- `scaler-controller` pod 正常運作。
- `prediction-service` 可從 cluster 內連線。
- `max_predicted_cpu` 是否真的超過 `SCALE_UP_THRESHOLD` 或低於 `SCALE_DOWN_THRESHOLD`。
- 是否仍在 `COOLDOWN_SECONDS` 時間內。
- RBAC 是否已套用。

```bash
kubectl logs -n smart-scaler deployment/scaler-controller -f
kubectl get clusterrole smart-scaler-role
kubectl get clusterrolebinding smart-scaler-binding
```

## 授權

本專案使用 MIT License。詳見 `LICENSE`。
