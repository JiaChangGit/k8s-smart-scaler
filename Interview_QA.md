# 台積電 IT 工程師面試問答完全指南
## K8s Smart Scaler 專案深度解析 × ICSD / BSID / AAID 面試準備

> 本文件根據 K8s Smart Scaler 專案（預測式 Kubernetes 自動擴縮容系統）整理，涵蓋系統設計、Kubernetes、監控、ML 預測、CI/CD、安全性等面向，適用於台積電 ICSD（基礎建設與雲端）、BSID（商業系統整合）、AAID（AI 應用整合）部門的技術面試準備。

---

## 目錄

1. [專案概述與動機](#一專案概述與動機)
2. [系統架構設計](#二系統架構設計)
3. [Kubernetes 核心知識](#三kubernetes-核心知識)
4. [監控與可觀測性](#四監控與可觀測性)
5. [時間序列預測與 ML](#五時間序列預測與-ml)
6. [自動擴縮邏輯](#六自動擴縮邏輯)
7. [CI/CD 與 DevOps](#七cicd-與-devops)
8. [安全性與權限設計](#八安全性與權限設計)
9. [測試策略](#九測試策略)
10. [設計限制與改進方向](#十設計限制與改進方向)
11. [情境題與行為面試](#十一情境題與行為面試)
12. [台積電 IT 部門針對性問題](#十二台積電-it-部門針對性問題)

---

## 一、專案概述與動機

### Q1：請用三分鐘介紹這個專案的核心價值。

**A：**

K8s Smart Scaler 是一個「預測式自動擴縮容（Predictive Autoscaling）」系統。傳統的 Kubernetes HPA（Horizontal Pod Autoscaler）是反應式（Reactive）的：流量增加 → CPU 超過門檻 → 建立新 Pod，這中間存在幾個延遲來源：

- Metrics scrape 時間間隔（15～60 秒）
- HPA 同步週期
- Pod 啟動時間（image pull + container start + readiness probe）

本專案改用預測式策略：收集歷史 CPU 時間序列 → 用 Facebook Prophet 預測未來 30 分鐘 CPU 走勢 → 提前在流量高峰前擴容，讓 Pod 在壓力來臨前已就緒。

架構上切分三個服務：`demo-app`（製造可觀測負載）、`prediction-service`（Prophet 預測）、`scaler-controller`（Kubernetes Deployment patch），每個服務責任清楚、可獨立替換，是典型的微服務分層設計。

---

### Q2：傳統 HPA 和你的預測式 Scaler 有什麼核心差異？各有什麼適用場景？

**A：**

| 維度 | 傳統 HPA | 預測式 Scaler（本專案） |
|------|----------|------------------------|
| 資料來源 | 當前/近期指標 | 歷史指標 → 預測未來 |
| 觸發時機 | 指標超過門檻後 | 預測超過門檻前 |
| 延遲 | 反應延遲 2～5 分鐘 | 提前 N 分鐘 |
| 複雜度 | 低，Kubernetes 原生 | 高，需維護預測模型 |
| 適用場景 | 負載不規律、無歷史規律 | 有週期規律（每日、每週）的流量 |

**適用場景舉例：**
- 台積電晶圓廠 EDA 工具在每天早上 8 點批次作業 → 適合預測式。
- 突發性事件（例如系統告警）→ 反應式 HPA 更合適。
- 最佳做法：兩者並用。HPA 保底應對突發，Predictive Scaler 提前應對規律高峰。

---

### Q3：為什麼選擇 Prophet 而不是 ARIMA 或 LSTM？

**A：**

Prophet 的選擇原因有三：

**1. 工程友好性**：Prophet 只需要 `ds`（時間）和 `y`（數值）兩個欄位，API 簡單，訓練快，不需要複雜的超參數調整。

**2. 適合 CPU 週期特性**：CPU 使用率通常有每日週期（上班時間高、凌晨低）和每週週期（平日 vs 假日）。Prophet 原生支援 `daily_seasonality` 和 `weekly_seasonality`，不需要手動 feature engineering。

**3. 不確定性區間**：Prophet 回傳 `lower_bound` 和 `upper_bound`，可以讓決策層使用保守估計（用 upper_bound 擴容），這在 ARIMA 中需要額外實作。

**ARIMA 的限制：** 不處理多重季節性，且需要資料平穩化（differencing），對短期劇烈變動不夠靈敏。

**LSTM 的限制：** 需要大量訓練資料和 GPU，推論延遲較高，對於每 60 秒做一次預測決策的場景來說過重。

---

## 二、系統架構設計

### Q4：請描述系統的完整資料流，從使用者請求到 Kubernetes 擴容的每一步。

**A：**

```
使用者/壓測腳本
    ↓ GET /work?intensity=85&duration=2
demo-app (FastAPI, Port 8001)
    ↓ 暴露 /metrics（Prometheus format）
Prometheus (Port 9090)
    ↓ 每 15 秒 scrape
    ↓ 儲存為 container_cpu_usage_seconds_total time series
prediction-service (Port 8000)
    ↓ 每次 /predict 呼叫時，用 PromQL query_range 取過去資料
    ↓ CPUPredictor.train() → Prophet 模型訓練
    ↓ 回傳 max_predicted_cpu / predictions[] / bounds
scaler-controller (背景輪詢，每 60 秒)
    ↓ 呼叫 prediction-service /predict?minutes_ahead=30
    ↓ 決策：max_predicted_cpu >= 70 → scale up
    ↓ math.ceil(current * ratio) 計算 desired replicas
    ↓ Kubernetes API patch_namespaced_deployment
Kubernetes Deployment Controller
    ↓ 讓實際 Pod 數量收斂至 desired
demo-app Pod 數量增加
```

整個流程體現 declarative control 思想：controller 宣告期望狀態，Kubernetes 負責讓系統收斂。

---

### Q5：這個系統的分層設計有什麼好處？如果要換掉預測模型，需要改動哪些地方？

**A：**

**分層設計的好處：**
- **可替換性（Replaceability）**：每個服務只透過 HTTP API 介面溝通，內部實作互不依賴。
- **可獨立部署（Independent Deployability）**：prediction-service 可以獨立更新模型版本，不需要重啟 scaler-controller 或 demo-app。
- **可測試性（Testability）**：CPUPredictor 可以獨立單元測試，不需要真的起 Kubernetes cluster。

**替換 Prophet 為 LSTM 需要改動的範圍：**

只需要修改 `prediction-service/app/predictor.py`：
- 把 `CPUPredictor.train()` 裡的 Prophet 換成 LSTM 訓練邏輯
- 把 `CPUPredictor.predict()` 換成 LSTM 推論邏輯
- 維持回傳格式（`predictions[]`、`max_predicted_cpu`、`lower_bound`、`upper_bound`）不變

**scaler-controller 完全不用改**，因為它只吃 `/predict` API 的 JSON 格式，不關心模型實作。這正是 API contract（介面契約）的價值。

---

### Q6：系統在 Docker Compose 和 Kubernetes 兩種模式下的主要差異是什麼？

**A：**

| 面向 | Docker Compose 模式 | Kubernetes (kind) 模式 |
|------|--------------------|-----------------------|
| 目的 | 快速體驗 API 和監控 | 完整 K8s 擴縮流程驗證 |
| Scaler Controller | 不運行（無法 patch K8s） | 運行，可真正 patch Deployment |
| Prometheus 設定 | `monitoring/prometheus.yml` 靜態設定 | kube-prometheus-stack + pod annotation |
| 服務發現 | Docker bridge network DNS | Kubernetes Service DNS |
| 儲存 | Docker Volume | K8s PersistentVolume（Helm 管理） |
| 網路 | host port mapping (8001, 8000, 9090, 3000) | NodePort 30080 / port-forward |
| 適合 | 開發者快速驗證、CI demo | 接近生產環境的整合測試 |

**關鍵限制：** Docker Compose 模式下 scaler-controller 沒有 Kubernetes cluster 可操作，所以看不到真正的 Deployment replicas 變化，只能驗證預測 API 本身。

---

## 三、Kubernetes 核心知識

### Q7：解釋 Deployment、ReplicaSet、Pod 三者的關係。

**A：**

這三者是 Kubernetes 管理 stateless 應用的層次結構：

```
Deployment（宣告期望狀態）
    └── ReplicaSet（維護 Pod 數量）
            ├── Pod（實際執行的 container）
            ├── Pod
            └── Pod
```

- **Deployment** 是使用者面向的物件，描述「我要跑什麼 image、幾個副本、如何更新」。
- **ReplicaSet** 是 Deployment 建立出來的，負責確保 Pod 數量符合 `spec.replicas`。當一個 Pod 意外死亡，ReplicaSet controller 會建立新 Pod。
- **Pod** 是最小執行單位，包含一個或多個 container。

**本專案的 patch 操作：**

```python
self.apps_v1.patch_namespaced_deployment(
    name="demo-app",
    namespace="demo",
    body={"spec": {"replicas": 3}},
)
```

這個 patch 改的是 Deployment，Deployment 會更新 ReplicaSet 的期望 Pod 數，ReplicaSet 再去建立或刪除 Pod。這是 declarative 設計的核心：使用者只宣告「我要 3 個 Pod」，Kubernetes 負責收斂。

---

### Q8：什麼是 RBAC？本專案為什麼需要 ClusterRole 而不是普通 Role？

**A：**

**RBAC（Role-Based Access Control）** 是 Kubernetes 的權限控制機制，決定「哪個 ServiceAccount 可以對哪些資源做哪些操作」。

**本專案 ClusterRole 定義：**

```yaml
apiGroups: ["apps"]
resources: ["deployments", "deployments/scale"]
verbs: ["get", "list", "watch", "update", "patch"]
```

**為什麼需要 ClusterRole 而不是 Role：**

- `Role` 只作用在單一 namespace。
- `ClusterRole` 可以跨 namespace 授權。

本專案的 scaler-controller 部署在 `smart-scaler` namespace，但需要 patch `demo` namespace 的 Deployment，因此必須使用 ClusterRole + ClusterRoleBinding 才能跨 namespace 操作。

**改進建議（台積電生產環境）：** 如果只需要操作 `demo` namespace，應改用 namespaced Role + RoleBinding，遵循 least privilege（最小權限）原則，降低 blast radius（爆炸半徑）。一旦 controller Pod 被攻破，ClusterRole 的攻擊面遠大於 namespaced Role。

---

### Q9：解釋 Kubernetes Service 的類型，以及本專案為什麼用 NodePort。

**A：**

Kubernetes Service 的主要類型：

| 類型 | 存取範圍 | 用途 |
|------|----------|------|
| ClusterIP | cluster 內部 | 服務間溝通，預設類型 |
| NodePort | 外部（透過 Node IP + 端口） | 開發/測試環境直接存取 |
| LoadBalancer | 外部（透過雲端 LB） | 生產環境對外服務 |
| ExternalName | 指向外部 DNS | 存取外部服務 |

**本專案用 NodePort 的原因：**

kind（Kubernetes in Docker）環境沒有雲端 Load Balancer，且 `kind-config.yaml` 已設定：

```yaml
extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
```

這讓 host 機器的 30080 port 直通 kind cluster 節點的 30080 NodePort，使 `curl http://localhost:30080` 可以打到 demo-app。

**在台積電生產環境：** 通常用 LoadBalancer（雲端）或搭配 Ingress Controller（NGINX Ingress / Istio Gateway）做 L7 路由，NodePort 主要用於 bare metal 或邊緣節點場景。

---

### Q10：什麼是 Kubernetes liveness probe 和 readiness probe？本專案如何設定？

**A：**

**Liveness Probe（存活探針）：** 檢查 container 是否還活著。失敗時 Kubernetes 會重啟 container。

**Readiness Probe（就緒探針）：** 檢查 container 是否準備好接受流量。失敗時 Kubernetes 把該 Pod 從 Service endpoint 移除，停止送流量進去。

**本專案設定：**

prediction-service 的 liveness probe 設定 `initialDelaySeconds: 60`，原因是 Prophet 模型訓練在啟動時就執行，可能需要 30～60 秒。如果 initialDelaySeconds 太短，Pod 還在訓練就被 liveness probe 判定失敗，導致重啟，形成 CrashLoopBackOff。

**最佳實踐：**
- Liveness probe：用 `/health` 輕量端點，只確認 process 活著。
- Readiness probe：用稍重的端點，確認服務依賴（DB、模型、Prometheus 連線）都就緒。
- 兩個 probe 應該有不同的路徑，不要混用。

---

### Q11：什麼是 ConfigMap？prediction-service 如何透過 ConfigMap 設定環境變數？

**A：**

ConfigMap 是 Kubernetes 用來儲存非機密設定的物件，讓設定值可以和 container image 分離。

**本專案用法：** `k8s/prediction-service/configmap.yaml` 存放：

```yaml
data:
  PROMETHEUS_URL: "http://prometheus-kube-prometheus-prometheus.monitoring:9090"
  TARGET_NAMESPACE: "demo"
  TARGET_DEPLOYMENT: "demo-app"
  LOG_LEVEL: "INFO"
```

然後在 Deployment 的 Pod spec 中注入：

```yaml
envFrom:
  - configMapRef:
      name: prediction-service-config
```

**ConfigMap vs Secret 的選擇：**
- ConfigMap：非機密設定（URL、namespace 名稱、log level）。
- Secret：機密設定（API key、DB 密碼、Docker Hub token）。本專案的 `DOCKERHUB_TOKEN` 存在 GitHub Secret，透過 CI/CD 傳入，不放在 ConfigMap。

---

## 四、監控與可觀測性

### Q12：解釋 Prometheus 的 scrape 機制和 counter vs gauge 的差異。

**A：**

**Scrape 機制：** Prometheus 主動 pull（而非 push）metrics。它定期（預設 15 秒）向目標的 `/metrics` HTTP endpoint 發送 GET 請求，解析 Prometheus exposition format 並儲存為 time series。

**Counter vs Gauge：**

| 類型 | 特性 | 例子 |
|------|------|------|
| Counter | 只增不減，代表累積值 | HTTP request 總數、CPU 使用秒數 |
| Gauge | 可增可減，代表當前值 | 記憶體使用量、並發連線數 |
| Histogram | 分佈統計 | HTTP request latency |
| Summary | 類似 Histogram，帶 quantile | 同上 |

**本專案的關鍵：**

`container_cpu_usage_seconds_total` 是 Counter，代表容器從啟動到現在累積使用 CPU 的秒數，只會增加。直接看這個值沒有意義，必須用 `rate()` 轉換：

```promql
rate(container_cpu_usage_seconds_total[5m])
```

這計算「每秒 CPU 使用率的 5 分鐘平均增長速率」，才能反映實際 CPU 使用率。

---

### Q13：解釋本專案的 PromQL 查詢，逐段說明每個篩選條件的用途。

**A：**

完整查詢：

```promql
avg(rate(container_cpu_usage_seconds_total{
  namespace="demo",
  pod=~"demo-app-.*",
  container!="POD",
  container!=""
}[5m])) * 100
```

**逐段解析：**

- `container_cpu_usage_seconds_total`：容器累積 CPU 使用秒數，Counter 類型。
- `{namespace="demo"}`：只看 `demo` namespace 的資料，排除其他 namespace 干擾。
- `{pod=~"demo-app-.*"}`：使用正則表達式，選出所有名稱以 `demo-app-` 開頭的 Pod（ReplicaSet 會產生像 `demo-app-7d9f8b-xkp2q` 的 Pod 名稱）。
- `{container!="POD"}`：排除 pause container（也叫 sandbox container，是 Kubernetes 網路命名空間的佔位符，不跑業務邏輯）。
- `{container!=""}`：排除 container 欄位為空的資料（可能是 cadvisor 回報的彙總行）。
- `rate(...[5m])`：計算 5 分鐘時間窗口內的每秒增長速率，將 Counter 轉成使用率。
- `avg(...)`：多個 Pod 間取平均。scale up 後有 3 個 Pod，取 avg 反映整體平均 CPU，而非某個 Pod 的值。
- `* 100`：從小數（0.3 = 30% CPU）轉成百分比（30）。

---

### Q14：Prometheus 在 Docker Compose 模式和 Kubernetes 模式下的差異，以及 pod annotation 是什麼？

**A：**

**Docker Compose 模式：** 使用靜態設定 `monitoring/prometheus.yml`：

```yaml
scrape_configs:
  - job_name: 'demo-app'
    static_configs:
      - targets: ['demo-app:8000']
```

明確告訴 Prometheus 去哪裡抓，不會自動發現新 target。

**Kubernetes 模式：** 使用 kube-prometheus-stack，透過 pod annotation 自動發現：

```yaml
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/port: "8000"
  prometheus.io/path: "/metrics"
```

Prometheus 的 kubernetes_sd_configs（Service Discovery）會掃描所有 Pod，看到 `prometheus.io/scrape: "true"` 就把這個 Pod 加入 scrape 目標，並使用對應的 port 和 path。

**優缺點對比：**
- 靜態設定：簡單，但 Pod 重啟換 IP 可能失效（Docker Compose 用 service name 解決了這個問題）。
- 自動發現：適合動態環境（Pod 數量變動），但需要正確的 annotation，錯誤的 annotation 可能導致 metrics 遺失。

---

### Q15：什麼是 Grafana？如何與 Prometheus 整合？

**A：**

Grafana 是可視化監控平台，可以連接各種資料來源（Prometheus、Elasticsearch、InfluxDB 等），製作互動式 Dashboard。

**與 Prometheus 整合方式：**
1. 在 Grafana 新增 Data Source，填入 Prometheus URL（`http://prometheus:9090`）。
2. 在 Dashboard 中建立 Panel，填入 PromQL 查詢。
3. Grafana 定期向 Prometheus 發送查詢，將結果渲染成圖表。

**本專案設定：**

```yaml
GF_SECURITY_ADMIN_USER: admin
GF_SECURITY_ADMIN_PASSWORD: admin123
```

帳密寫在 docker-compose.yml 是 demo 用的做法。**生產環境應使用 Kubernetes Secret**，或整合 LDAP/SSO（台積電 IT 環境通常接 AD/Azure AD）。

**台積電常用監控場景：** 製程良率趨勢、設備稼動率、IT 系統 SLA 監控等，都可以用 Grafana 做 Dashboard。

---

## 五、時間序列預測與 ML

### Q16：Prophet 是什麼？它的數學模型長什麼樣？本專案的參數設定各自代表什麼？

**A：**

Prophet 是 Meta 開源的時間序列預測工具，模型結構為：

```
y(t) = trend(t) + seasonality(t) + holidays(t) + error(t)
```

- **trend**：整體趨勢，Prophet 支援線性（linear）和對數增長（logistic growth）。
- **seasonality**：週期性成分，用傅立葉級數（Fourier series）近似。
- **holidays**：假日效應（本專案未啟用）。
- **error**：隨機雜訊。

**本專案參數：**

```python
Prophet(
    changepoint_prior_scale=0.05,  # 趨勢變化點敏感度，越大越追隨突變，越小越平滑
    seasonality_mode="multiplicative",  # 季節性是乘法型（波動隨基準值成比例），適合 CPU
    daily_seasonality=True,   # 每日週期（上班時間 CPU 高）
    weekly_seasonality=True,  # 每週週期（平日 vs 假日）
    interval_width=0.95,      # 預測區間寬度（95% 信賴區間）
    uncertainty_samples=200,  # 抽樣次數，越多估計越準確但越慢
)
```

**seasonality_mode 選 multiplicative 的原因：** CPU 在基準 50% 時的波動和基準 10% 時的波動幅度不同。乘法型考慮了這個比例關係，比加法型（additive）更適合 CPU 使用率資料。

---

### Q17：什麼是 3-sigma 異常值過濾？本專案為什麼需要它？

**A：**

**3-sigma rule（三標準差法則）：** 基於常態分布假設，約 99.7% 的資料落在平均值正負三個標準差內。超出這個範圍的資料視為異常值（outlier）。

**本專案實作：**

```python
mean_y = df["y"].mean()
std_y = df["y"].std()
df = df[(df["y"] >= mean_y - 3 * std_y) & (df["y"] <= mean_y + 3 * std_y)]
df["y"] = df["y"].clip(0, 100)
```

**為什麼需要：**

Prometheus 的時間序列資料可能出現：
- 短暫的 scrape 錯誤導致的極端值（例如 CPU 突然顯示 500%）。
- 容器重啟瞬間的 counter reset 導致的負值或異常跳變。
- 網路延遲導致的重複資料。

如果把 CPU = 500% 直接餵給 Prophet，模型會認為趨勢大幅上升，預測出不合理的結果，進而觸發不必要的 scale up。

**更進一步：** 台積電 IT 系統的 metrics 可能也有類似問題（設備 sensor 偶爾讀值異常），3-sigma 過濾是基礎但有效的處理手段。對於更嚴格的需求，可以用 IQR（四分位距）方法，對非常態分布的資料更穩健。

---

### Q18：如何評估 Prophet 模型的預測品質？本專案目前有沒有這個機制？

**A：**

**常用評估指標：**

| 指標 | 全名 | 說明 | 公式 |
|------|------|------|------|
| MAE | Mean Absolute Error | 平均絕對誤差 | mean(|y - ŷ|) |
| RMSE | Root Mean Squared Error | 均方根誤差，對大誤差懲罰更重 | sqrt(mean((y - ŷ)²)) |
| MAPE | Mean Absolute Percentage Error | 平均絕對百分比誤差，百分比表示 | mean(|y - ŷ| / y) * 100 |

**本專案現狀：** 目前沒有模型品質評估機制，這是報告中明確指出的設計限制之一。

**改進方案：** 訓練時使用 walk-forward validation（時序交叉驗證）：
- 前 80% 作為 train set。
- 後 20% 作為 validation set。
- 計算 MAE、RMSE、MAPE。
- 若 MAPE > 30%，controller 應停止使用預測結果做擴縮，避免基於不可信模型做決策。

**在台積電的應用：** 台積電設備預測性維護（Predictive Maintenance）同樣需要模型品質追蹤，確保模型沒有 concept drift（概念漂移），這個評估框架是可以直接套用的。

---

### Q19：什麼是 concept drift？Prediction Service 如何應對？

**A：**

**Concept drift** 是指資料的統計分佈隨時間變化，導致原本訓練的模型預測準確度下降。

**CPU 場景的例子：**
- 原本系統平日 CPU 平均 30%，模型依此訓練。
- 三個月後新服務上線，平均 CPU 變成 60%。
- 舊模型預測結果持續偏低，導致 scale up 不足。

**本專案的應對：** 實作了 `POST /train` 端點和背景定期重訓（background retraining）。每次重訓都用最新的 Prometheus 歷史資料，所以模型會逐漸適應新的 CPU 基準。

**限制：** 目前沒有偵測 drift 的主動機制。改進方案是定期計算預測誤差，若誤差持續上升則觸發告警和強制重訓。

---

## 六、自動擴縮邏輯

### Q20：詳細說明 scaler-controller 的擴縮決策邏輯，用具體數字舉例。

**A：**

**Scale Up 邏輯（按比例擴容）：**

```python
if max_cpu >= SCALE_UP_THRESHOLD:  # 預設 70.0
    ratio = max_cpu / SCALE_UP_THRESHOLD
    desired = math.ceil(current * ratio)
    desired = max(current + 1, desired)  # 至少增加 1
```

**具體例子：**
- 當前 replicas = 2，預測 max_predicted_cpu = 91%。
- ratio = 91 / 70 = 1.3。
- desired = ceil(2 × 1.3) = ceil(2.6) = 3。
- 最終 desired = max(2+1, 3) = 3。

**Scale Down 邏輯（每次縮 1）：**

```python
elif max_cpu < SCALE_DOWN_THRESHOLD:  # 預設 30.0
    desired = current - 1
```

縮容更保守，每次只縮 1 個，避免縮過頭。

**Cooldown 機制：**

```python
COOLDOWN_SECONDS = 120
```

每次擴縮後 120 秒內不再做任何擴縮，避免 flapping（震盪）。

**邊界限制：**

```python
desired = max(MIN_REPLICAS, min(MAX_REPLICAS, desired))  # 限制在 1～10
```

---

### Q21：Cooldown 和 HPA 的 Stabilization Window 有什麼不同？各有什麼優缺點？

**A：**

**Cooldown（本專案）：**
- 機制：擴縮後固定一段時間（120 秒）不做任何操作。
- 優點：實作簡單，避免連續擴縮。
- 缺點：Cooldown 期間即使有新的高峰預測，也不會反應。

**Stabilization Window（HPA）：**
- 機制：保留過去時間窗口內所有建議的 desired replicas，scale down 時取最大值，避免過早縮容。

```text
過去 5 分鐘建議: [5, 4, 3, 2]
scale down stabilization → 取 max = 5
→ 不縮容，維持 5 個 Pod 的安全緩衝
```

- 優點：對 scale down 更保守，對 scale up 無額外延遲。
- 缺點：實作複雜，需維護歷史建議值。

**本專案的改進方向：** 實作類似 stabilization window 的機制：

```python
recent_recommendations = deque(maxlen=5)  # 保留最近 5 次建議
scale_down_desired = max(recent_recommendations)  # 保守縮容
```

---

### Q22：如果 scaler-controller 和 HPA 同時運行，會發生什麼問題？如何解決？

**A：**

**問題：兩個 controller 同時寫 Deployment.spec.replicas 會產生衝突（conflict）。**

場景：
1. HPA 把 replicas 設為 5（因為當前 CPU 高）。
2. scaler-controller 把 replicas 設為 3（因為預測 CPU 將低）。
3. 兩者互相覆寫，replicas 在 3 和 5 之間震盪。

**解決方案（三種）：**

**方案一：Smart Scaler 改調整 HPA 的 minReplicas（最推薦）**

```python
# 不直接 patch Deployment，改 patch HPA
autoscaling_v2.patch_namespaced_horizontal_pod_autoscaler(
    name="demo-app",
    namespace="demo",
    body={"spec": {"minReplicas": predicted_min}},
)
```

HPA 仍是 replicas 的主控，Smart Scaler 只調整保底容量，職責清楚。

**方案二：Smart Scaler 輸出 custom metric，HPA 消費**

```
prediction-service → /predicted_cpu metric → Prometheus → Prometheus Adapter → HPA
```

**方案三：擇一使用**
- 有規律週期高峰 → 用 Smart Scaler。
- 無規律突發 → 用 HPA。

---

## 七、CI/CD 與 DevOps

### Q23：說明 ci-cd.yml 的三個 Job 各做什麼，以及 Job 間如何傳遞依賴。

**A：**

**Job 1：Test（`🧪 Run Tests`）**

觸發條件：push 到 `main`/`develop`，或對 `main` 開 PR。

步驟：
1. Checkout code
2. 設定 Python 3.11 環境（含 pip cache，加速後續 run）
3. 安裝 `prediction-service/requirements.txt`
4. 執行 `python -m pytest tests/ -v --tb=short`

**Job 2：Build & Push（`🐳 Build & Push Images`）**

觸發條件：`needs: test` + `if: github.ref == 'refs/heads/main'`（只在 main branch test 通過後執行）。

使用 **matrix strategy** 同時建立三個 image：
- `k8s-smart-scaler-prediction`
- `k8s-smart-scaler-controller`
- `k8s-smart-scaler-demo`

標籤策略：
- `sha-<短commit hash>`：每次 commit 有唯一標籤，方便回滾。
- `latest`：永遠指向最新版本。

使用 `cache-from/cache-to: type=gha` 利用 GitHub Actions cache 加速 Docker build。

**Job 3：Deploy（`🚀 Deploy to K8s`）**

目前設定 `if: false`，不執行。若啟用需要：
- `KUBE_CONFIG` secret（base64 kubeconfig）
- 替換 manifest 中的 image tag

**Job 依賴關係：**
```
Test ──成功──> Build & Push ──成功──> Deploy
```

`needs: test`、`needs: build-and-push` 是宣告式依賴，GitHub Actions 保證前者成功才執行後者。

---

### Q24：為什麼 Image 用 sha tag 而不只用 latest？這對台積電 IT 環境有什麼意義？

**A：**

**只用 latest 的風險：**

`latest` tag 是可變的（mutable），每次 push 都會覆蓋。在 Kubernetes 中，如果 `imagePullPolicy: Always` 且只用 `latest`：
- 不同時間部署的環境可能跑不同版本（環境不一致）。
- 回滾困難：要找到「上一個 latest」對應的程式碼非常困難。
- Kubernetes 的 rollout history 失去意義。

**sha tag 的好處：**

每個 commit 對應唯一的 image，例如 `jiachanggit/k8s-smart-scaler-demo:sha-a3f8c12`：
- **可重現（Reproducible）**：任何時間部署這個 tag，都是同一份程式碼。
- **可追蹤（Traceable）**：從 image tag 可以直接對應到 Git commit，排查問題效率高。
- **可回滾（Rollable）**：`kubectl set image deployment/demo-app demo-app=image:sha-prev` 可以精確回滾到任一版本。

**台積電 IT 情境：** 台積電 IT 系統涉及生產資料和設備控制，版本追蹤和回滾能力是 ITSM（IT Service Management）的基本要求，sha tag 是最佳實踐。

---

### Q25：如何設計一個適合台積電製造環境的 CI/CD pipeline？

**A：**

台積電 IT 系統的特殊需求：
1. **變更管理（Change Management）**：所有生產環境變更需要審批流程（ITIL）。
2. **測試環境隔離**：Dev → SIT → UAT → Production，不同環境有不同的驗證標準。
3. **安全掃描**：容器 image 需要通過漏洞掃描（Trivy、Snyk）。
4. **合規性**：SOX、ISO 27001 等要求稽核日誌。

**建議的 Pipeline 設計：**

```
Code Commit
  │
  ▼ (自動)
Unit Test + Static Analysis (SonarQube)
  │
  ▼ (自動)
Build Image + 漏洞掃描 (Trivy)
  │
  ▼ (自動)
Deploy to DEV → Integration Test
  │
  ▼ (自動)
Deploy to SIT → System Test
  │
  ▼ (人工審批: Manager/QA)
Deploy to UAT → User Acceptance Test
  │
  ▼ (變更管理審批 + 排定維護窗口)
Deploy to Production (藍綠部署或 Canary)
  │
  ▼ (自動)
Smoke Test → 監控 30 分鐘 → 完成或自動回滾
```

本專案的 `if: false` deploy job 就是預留了這個擴展空間，只需要補上環境判斷和審批機制。

---

## 八、安全性與權限設計

### Q26：本專案的 ClusterRole 存在哪些安全風險？如何在台積電生產環境改善？

**A：**

**現有風險：**

1. **過大的權限範圍（Over-privileged）**：ClusterRole 允許 controller 存取所有 namespace 的 Deployment。若只需要操作 `demo` namespace，這是不必要的授權。

2. **過多的 verbs**：給了 `list`、`watch` 除了 `patch` 之外的權限，理論上 scaler-controller 應該只需要 `get`（確認當前 replicas）和 `patch`（修改 replicas）。

3. **ServiceAccount 可被任意 Pod 使用**：若攻擊者在 `smart-scaler` namespace 起了惡意 Pod 並掛載同一個 ServiceAccount，可以任意修改 Deployment。

**改善方案：**

```yaml
# 改用 namespaced Role，只授權 demo namespace
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: smart-scaler-role
  namespace: demo  # 限定在 demo namespace
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  resourceNames: ["demo-app"]  # 只允許操作特定 Deployment
  verbs: ["get", "patch"]  # 最小必要權限
```

**台積電生產建議：**
- 使用 OPA（Open Policy Agent）或 Kyverno 做 admission control，確保新建的 ServiceAccount 不能輕易取得高權限。
- 定期使用 `kubectl auth can-i` 稽核 RBAC 設定。
- 啟用 Kubernetes Audit Log，記錄所有 API server 操作。

---

### Q27：預測服務的 synthetic data fallback 在生產環境有什麼安全疑慮？

**A：**

**問題描述：** 當 Prometheus 無法查詢到資料時，prediction-service 會產生「合成 CPU 資料（synthetic data）」繼續回傳預測結果，讓 demo 環境在沒有真實監控資料的情況下也能跑起來。

**生產環境的風險：**

1. **假資料驅動真實決策**：scaler-controller 不知道資料是合成的，仍然會根據這個假資料 patch Deployment replicas，可能導致：
   - 不必要的 scale up（浪費資源）。
   - 錯誤的 scale down（服務降級）。

2. **掩蓋監控系統故障**：Prometheus 掛掉了，系統仍然「看起來正常運作」，讓 SRE 不知道監控已失效。

**改善方案：**

```python
# 改成：Prometheus 不可用時，回傳明確的錯誤狀態
if not prometheus_data:
    raise HTTPException(
        status_code=503,
        detail="Prometheus unavailable, scaling suspended"
    )
```

並且 scaler-controller 在收到 503 時應：
1. 記錄告警（Alert）。
2. 停止本次擴縮決策。
3. 不影響 Cooldown 計時器。

---

### Q28：什麼是 leader election？本專案為什麼需要它？

**A：**

**Leader Election（領導者選舉）** 是分散式系統中確保「同一時間只有一個實例執行關鍵任務」的機制。

**本專案的問題：** 如果 scaler-controller 有 2 個 replica（為了高可用），兩個 controller 同時讀取預測結果、同時 patch Deployment，可能產生：
- 重複決策（兩個 controller 各自計算 desired，相互覆寫）。
- Race condition（同時讀到 current=2，各自計算 desired=3，最後都 patch 3，還好；但若邏輯更複雜則可能出問題）。

**Kubernetes 的 Leader Election 機制：** 使用 Lease 資源（或 ConfigMap/Endpoint）做分散式鎖。只有持有 Lease 的 Pod（leader）才執行業務邏輯，其他 Pod 為 standby，定期嘗試取得 Lease。

**本專案現狀：** 固定 `replicas: 1`，以單一實例避免此問題。這是 demo 環境的簡化做法，生產環境應引入 leader election（可使用 `controller-runtime` 函式庫，它內建 leader election 支援）。

---

## 九、測試策略

### Q29：prediction-service 的單元測試覆蓋哪些面向？如何設計更完整的測試策略？

**A：**

**現有測試（`tests/test_predictor.py`）：**

測試項目：
1. 初始狀態（模型未訓練）
2. 資料不足時不訓練（少於最小樣本數）
3. 訓練成功
4. 未訓練時呼叫 predict 回傳錯誤
5. 預測資料結構驗證（有正確的欄位）
6. CPU 預測值範圍（0 到 100 之間）
7. 不同預測時間長度（5 分鐘 vs 60 分鐘）

**缺少的測試層次：**

| 測試類型 | 內容 | 工具 |
|----------|------|------|
| Unit Test | CPUPredictor 邏輯（現有） | pytest |
| Integration Test | prediction-service + 真實 Prometheus | pytest + testcontainers |
| Contract Test | /predict API 回傳格式驗證 | pact / schemathesis |
| E2E Test | 完整擴縮流程 | kind + k6/hey |
| Chaos Test | Prometheus 掛掉時的 fallback 行為 | chaos-mesh |

**完整測試策略（台積電生產建議）：**

```
Unit Test (pytest)        → 每次 commit
Integration Test          → PR merge 時
Contract Test             → 每日
E2E Test (kind cluster)   → 每週 / 每次 release
Chaos Test                → 每季 disaster recovery drill
```

---

### Q30：如何在不依賴真實 Prometheus 的情況下測試 prediction-service？

**A：**

**方法一：Mock Prometheus Client（現有方式的延伸）**

```python
@pytest.fixture
def mock_metrics():
    return [
        {"timestamp": "2024-01-01T08:00:00", "cpu_usage": 30.0},
        {"timestamp": "2024-01-01T08:05:00", "cpu_usage": 45.0},
        # ... 至少 10 筆
    ]

def test_train_with_mock_data(mock_metrics):
    predictor = CPUPredictor()
    predictor.train(mock_metrics)
    assert predictor.is_trained
```

**方法二：Prometheus mock server（適合 Integration Test）**

使用 `pytest-httpserver` 或 `responses` 套件模擬 Prometheus HTTP API：

```python
with httpserver.expect_request("/api/v1/query_range").respond_with_json(mock_response):
    result = collector.fetch_metrics()
    assert len(result) > 0
```

**方法三：Testcontainers（最接近真實）**

```python
from testcontainers.core.container import DockerContainer

def test_with_real_prometheus():
    with DockerContainer("prom/prometheus").with_exposed_ports(9090) as prometheus:
        url = f"http://localhost:{prometheus.get_exposed_port(9090)}"
        collector = PrometheusCollector(prometheus_url=url)
        # 測試真實查詢
```

---

## 十、設計限制與改進方向

### Q31：本專案有哪些設計限制？如果你要把它推上台積電生產環境，優先改什麼？

**A：**

**目前已知的設計限制：**

1. CPU 查詢用平均值，沒有考慮最大值或 p95 值
2. 沒有真正整合 Kubernetes HPA
3. 沒有 leader election
4. 沒有持久化模型（每次重啟要重新訓練，需要 60 秒初始化時間）
5. 沒有模型品質評估（MAE、RMSE、MAPE）
6. 沒有事件記錄到 Kubernetes Event
7. 沒有處理預測 uncertainty 對決策的影響
8. Prometheus fallback synthetic data 不適合 production 自動決策
9. Deploy CI/CD job 目前關閉
10. ClusterRole 權限過大

**台積電生產環境優先改進順序：**

**P0（上線前必改）：**
1. **關閉 synthetic data fallback**：Prometheus 不可用時應停止擴縮並告警。
2. **ClusterRole 縮小為 namespaced Role**：安全性基本要求。
3. **補充模型品質評估**：避免基於壞模型做決策。

**P1（上線後 30 天內）：**
4. **模型持久化**（Redis 或 S3 存 model artifact）：避免 Pod 重啟重新訓練。
5. **Kubernetes Events 記錄**：提升可觀測性。
6. **Leader election**：支援 HA 部署。

**P2（長期優化）：**
7. **整合 HPA minReplicas**：更健壯的控制架構。
8. **OpenTelemetry distributed tracing**：完整可觀測性三支柱。

---

### Q32：如果 Prediction Service 本身掛掉，scaler-controller 應該怎麼處理？

**A：**

這是系統容錯設計（Fault Tolerance）的重要問題。

**當前行為：** scaler-controller 呼叫 `/predict` 失敗，記錄 error log，等待下一個 CHECK_INTERVAL（60 秒）重試。由於有 Cooldown 保護，短暫失敗不會立即影響現有 replica 數量。

**潛在問題：** 如果 Prediction Service 長時間不可用（例如 > 10 分鐘），scaler-controller 持續失敗，系統停止所有擴縮決策。若這期間真的有流量高峰，系統無法 scale up。

**改善方案（Fallback 策略）：**

```python
class ScalerController:
    def __init__(self):
        self.last_successful_prediction = None
        self.prediction_failure_count = 0
        self.MAX_FAILURE_BEFORE_ALERT = 3
    
    def run_cycle(self):
        try:
            prediction = self.fetch_prediction()
            self.last_successful_prediction = prediction
            self.prediction_failure_count = 0
            self.decide_and_scale(prediction)
        except Exception as e:
            self.prediction_failure_count += 1
            if self.prediction_failure_count >= self.MAX_FAILURE_BEFORE_ALERT:
                self.send_alert("Prediction Service unavailable for {} cycles")
            # 不縮容，保持現有 replicas（safe mode）
```

**台積電設計原則：** 在不確定性高的情況下，保守地「不動」比激進地「錯動」更安全。這是 fail-safe 設計原則。

---

## 十一、情境題與行為面試

### Q33：如果監控資料顯示預測準確率突然下降，你會怎麼排查？

**A：**

**系統性排查步驟（5W1H）：**

**Step 1：確認現象範圍**
- 是所有預測都偏差，還是特定時間段？
- MAPE 是多少？上升趨勢是從何時開始？

**Step 2：排查資料層**
- Prometheus 資料是否正常？`curl /metrics/current` 查看當前 CPU。
- 是否有資料缺口（scrape 失敗）？查 Prometheus Targets 頁面。
- 異常值過濾是否過濾掉了太多正常資料？

**Step 3：排查模型層**
- 最後一次重訓是什麼時候？訓練資料的時間範圍是多少？
- 是否有 concept drift？業務行為改變了嗎（新服務上線、用戶量增長）？

**Step 4：排查預測參數**
- `changepoint_prior_scale` 是否需要調高，讓模型更快適應趨勢變化？
- 預測視窗（30 分鐘）是否適合當前業務模式？

**Step 5：應急處置**
- 暫時讓 scaler-controller 進入 safe mode（不擴縮），避免基於壞模型做決策。
- 手動 patch Deployment 到合理的 replica 數。
- 觸發強制重訓並評估新模型品質。

---

### Q34：如果被分配到台積電 ICSD 負責 Kubernetes 基礎設施，你會如何規劃？

**A：**

台積電 ICSD 的 Kubernetes 基礎設施規劃重點：

**可靠性（Reliability）：**
- Multi-AZ/Multi-Zone cluster 避免單點故障。
- etcd 備份（每日備份 + 跨地域儲存）。
- Node 自動修復（node problem detector + cluster autoscaler）。

**安全性（Security）：**
- Pod Security Standards（Restricted）：禁止 privileged container。
- Network Policy：預設 deny all，只開必要的服務間通信。
- Image Scanning：所有 image 需通過 Trivy 掃描才能部署。
- Secrets Management：整合 HashiCorp Vault 或 Azure Key Vault，不將 secret 明文存在 K8s Secret（base64 不等於加密）。

**可觀測性（Observability）：**
- Prometheus + Grafana：指標監控。
- Loki 或 Elasticsearch：集中日誌。
- Jaeger 或 Tempo：分散式追蹤。
- SLA Dashboard：關鍵服務的 P99 latency、error rate、availability。

**效率（Efficiency）：**
- Cluster Autoscaler：動態擴縮 Node 數量。
- VPA（Vertical Pod Autoscaler）：自動調整 resource request/limit。
- 結合本專案的預測式 HPA 擴縮。

**台積電特殊考量：**
- 工廠環境 OT（Operational Technology）和 IT 網路隔離，需要明確的 DMZ 設計。
- 設備介面服務可能需要 StatefulSet 而非 Deployment（有狀態）。
- 合規性稽核日誌需要符合 ISO 27001 要求。

---

### Q35：你在這個專案裡遇到最大的技術挑戰是什麼？怎麼解決的？

**A（示範回答）：**

最大的挑戰是讓 Prophet 在資料不足的情況下優雅降級，而不是崩潰。

Prophet 需要足夠的訓練資料才能識別季節性（通常建議至少幾週的資料）。在 Demo 環境剛啟動時，Prometheus 只有幾分鐘的 CPU 歷史，Prophet 訓練可能失敗，或產生不可信的預測。

**解決過程：**

1. **識別問題**：在 CI 測試中發現 `test_insufficient_data_no_train` 案例失敗，因為 Prophet 在少量資料下拋出異常而非返回適當的錯誤狀態。

2. **加入最小樣本數守衛**：

```python
MIN_TRAINING_SAMPLES = 10

def train(self, metrics_data):
    if len(metrics_data) < MIN_TRAINING_SAMPLES:
        logger.warning("Insufficient data for training")
        return False
```

3. **加入合成資料 fallback**：讓 demo 環境在沒有真實資料時也能展示完整流程，但同時在 API 回應中標記 `data_source: "synthetic"`，讓 caller 知道資料來源。

4. **補強測試**：針對邊界案例（0 筆、5 筆、10 筆、11 筆資料）各寫一個測試案例。

這個過程讓我深刻理解，ML 模型的工程化不只是訓練準確，更要考慮各種異常輸入的安全處理。

---

## 十二、台積電 IT 部門針對性問題

### Q36（ICSD 專向）：台積電的 Kubernetes 環境通常跑在哪種基礎設施上？如何選擇 on-premise vs cloud？

**A：**

台積電的 IT 基礎設施考量：

**On-premise 的優勢（台積電較常見）：**
- **資料主權**：晶圓製程配方（Recipe）、良率資料屬於高度機密，不能輕易放上公有雲。
- **低延遲**：工廠自動化（EAP, Equipment Automation Program）對延遲敏感，on-premise 更可控。
- **合規性**：半導體產業供應鏈安全要求（SEMI E187 等）。

**Cloud 的適用場景：**
- 非機密的辦公系統、ERP 周邊功能。
- 彈性運算需求（例如 EDA 工具批次模擬）→ HPC on cloud（AWS HPC、Azure HPC）。
- DR（Disaster Recovery）備援環境。

**本專案的架構選擇建議：**
- scaler-controller + prediction-service → on-premise K8s（靠近監控資料）。
- CI/CD pipeline → cloud 或混合（GitHub Actions / GitLab CI）。
- Model artifact 儲存 → on-premise MinIO（S3-compatible）。

---

### Q37（BSID 專向）：如果這個預測式擴縮系統要整合台積電的 SAP ERP 或 MES 系統，需要考慮什麼？

**A：**

BSID 負責商業系統整合，整合 ERP/MES 的考量：

**資料整合層：**
- MES（Manufacturing Execution System）會產生大量 event（製程步驟完成、批次移轉等），這些 event 是比 CPU 更有預測價值的信號。
- 例如：MES 告知「未來 2 小時有 500 片晶圓要跑 CMP（化學機械研磨）」→ 預測式 Scaler 可以提前擴充 CMP 排程系統的運算 Pod。

**整合架構：**

```
MES Event Stream (Kafka / MQ)
    → Prediction Service (消費 MES 事件作為額外特徵)
    → Prophet（多特徵預測，結合 CPU + MES workload forecast）
    → scaler-controller
    → K8s Deployment
```

**特殊考量：**
- MES 資料通常在 OT 網路，需要透過 DMZ 安全地送到 IT 網路。
- MES 資料可能有延遲或亂序（OPC UA / MQTT 協議），需要 event ordering 處理。
- SAP ERP 的訂單資料（生產計畫）→ 可以轉換成未來負載預估的輸入特徵。

---

### Q38（AAID 專向）：如果要把這個系統的 ML 能力升級為 GenAI 應用，你會怎麼設計？

**A：**

AAID 負責 AI 應用整合，GenAI 升級方向：

**方向一：LLM 輔助異常解釋**

當 scaler-controller 觸發非預期的大幅擴縮時，讓 LLM 分析相關 metrics 和 logs，自動產生人類可讀的根因分析報告：

```
Prometheus metrics → LLM (GPT-4 / Claude) → 
"今天 14:30 scale up from 2 to 8 的原因是：
MES 系統批次跑了 400 片 wafer 的 OPC，造成 data analysis service CPU 從 30% 升至 85%，
符合每月第三週四的歷史規律。"
```

**方向二：強化學習替代門檻決策**

用 RL（Reinforcement Learning）替換目前固定門檻（70%/30%）的決策邏輯：
- State：當前 CPU、replicas、預測值、cooldown 狀態。
- Action：scale up / scale down / no-op。
- Reward：最小化 SLA 違反次數 + 最小化不必要的 Pod 成本。

**方向三：多模態預測**

結合 CPU metrics + 文字型 event（MES log、ERP 訂單備註）做預測：
- 用 text embedding 將非結構化資料轉成特徵向量。
- 與時間序列特徵融合輸入預測模型。

**台積電 AAID 的現實考量：**
- LLM 的機密資料保護（不能把製程資料送到外部 API，需要 on-premise LLM）。
- 推論延遲（決策需要在 60 秒 check cycle 內完成）。
- 模型可解釋性（對工程師和主管的決策可信度）。

---

## 快速記憶卡（面試前 30 分鐘複習）

### 核心數字

| 參數 | 值 | 說明 |
|------|----|------|
| CHECK_INTERVAL | 60 秒 | scaler-controller 輪詢間隔 |
| LOOKAHEAD_MINUTES | 30 分鐘 | 預測視窗 |
| COOLDOWN_SECONDS | 120 秒 | 擴縮後冷卻時間 |
| SCALE_UP_THRESHOLD | 70% | CPU 高於此值 scale up |
| SCALE_DOWN_THRESHOLD | 30% | CPU 低於此值 scale down |
| MIN_REPLICAS | 1 | 最小 Pod 數 |
| MAX_REPLICAS | 10 | 最大 Pod 數 |
| initialDelaySeconds | 60 秒 | Prediction Service liveness probe 等待時間 |
| interval_width | 0.95 | Prophet 95% 信賴區間 |

### 核心架構關鍵字

- **Predictive Autoscaling** vs Reactive HPA
- **Prophet** = trend + seasonality + holidays
- **PromQL**: `rate(counter[5m]) * 100`
- **RBAC**: ClusterRole → ClusterRoleBinding → ServiceAccount → Pod
- **Declarative Control**: patch spec.replicas → Kubernetes 收斂
- **Cooldown** vs **Stabilization Window**
- **Synthetic data**: demo 友好但 production 危險
- **Leader Election**: 避免多 controller 衝突
- **SHA tag**: 可重現、可追蹤、可回滾

### 常見追問與一句話回答

- **為什麼用 rate() 而不直接用 counter？** Counter 只增不減，rate() 才能轉成每秒變化率。
- **為什麼要 3-sigma 過濾？** 避免短暫異常值讓 Prophet 訓練偏差。
- **ClusterRole 和 Role 的差異？** ClusterRole 可跨 namespace，Role 只在單一 namespace 有效。
- **cooldown 的目的？** 避免擴縮震盪（flapping）。
- **synthetic data 的風險？** 假資料驅動真實 K8s 操作，生產不可用。
- **為什麼 single worker？** 模型在 process memory 的全域變數，多 worker 會各自維護不同模型狀態。

---

*本文件版本：2026-05 | 基於 K8s Smart Scaler 專案分析*
