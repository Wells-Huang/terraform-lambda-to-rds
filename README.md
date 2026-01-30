## 專案簡介
利用Terraform透過main.tf部署Lambda, RDS database (Postgress), 以及相關元件
接著透過aws指令或Lambda test function確認Lambda與資料庫的連接成功

## 2026-01-30 重大更新：交替使用者輪換 (Alternating Users Rotation)

本專案已升級 AWS Secrets Manager 輪換策略，採用「交替使用者」模式，以確保資料庫憑證在輪換期間**零停機 (Zero Downtime)**。

### 1. 設計目標與原理

#### 目標
解決舊有「單一使用者輪換」在更改密碼瞬間會造成既有連線中斷的問題。我們的目標是提供一個「緩衝期」，確保新舊密碼在輪換期間同時有效。

#### 做法 (How it works)
系統維護兩個資料庫使用者帳號：`app_user` 與 `app_user_clone`。Secret (`app-db-credentials`) 會在這兩個使用者之間輪流切換。

**輪換流程範例：**
1.  **初始狀態**：Secret 指向 `app_user` (密碼 A)。應用程式連線中。
2.  **觸發輪換**：
    *   系統選定閒置的 `app_user_clone`。
    *   系統將 `app_user_clone` 的密碼更新為新亂數密碼 (密碼 B)。
    *   Secret 更新指向 `app_user_clone` (密碼 B)。
3.  **緩衝期 (關鍵)**：
    *   **新連線**：讀取 Secret 取得 `app_user_clone` (密碼 B)，連線成功。
    *   **舊連線**：仍持有 `app_user` (密碼 A) 的應用程式**不會斷線**，因為我們沒有動 `app_user` 的密碼。
4.  **下一次輪換**：
    *   系統選定現在變成舊帳號的 `app_user`。
    *   更新 `app_user` 為新密碼 (密碼 C)。
    *   Secret 切換回 `app_user`。此時原本的密碼 A 才會失效。

### 2. 部署與初始化步驟

在 wsl 環境下：

1.  **部署資源**
    ```bash
    terraform init
    terraform apply -var="db_password=YOUR_INITIAL_PASSWORD"
    ```

2.  **【關鍵步驟】初始化應用程式使用者**
    部署後必須執行此初始化指令，它會同時建立 `app_user` 和 `app_user_clone` 兩個使用者。
    *(因為 AWS 沒有提供直接建立 DB User 的 API，我們透過 Lambda 執行 SQL)*

    ```bash
    # 使用 payload.json 避免 Windows CLI 引號問題
    echo '{"sql_file": "init_app_user.sql"}' > payload.json
    aws lambda invoke --function-name RDSAdmin --payload file://payload.json --cli-binary-format raw-in-base64-out response_init.json
    ```
    *檢查 `response_init.json` 確認回傳 "Successfully executed..."*

### 3. 驗證方式 (Verification)

您可以透過以下步驟驗證「交替使用者」機制是否正常運作。

#### 3.1 準備工作
取得 App User 的 Secret 名稱 (例如 `app-db-credentials-xxxx`)：
```bash
export SECRET_NAME=$(aws secretsmanager list-secrets --query "SecretList[?starts_with(Name, 'app-db-credentials')].Name" --output text)
echo $SECRET_NAME
```

#### 3.2 驗證初始狀態
讀取目前的 Secret，確認目前指向的使用者 (預設應為 `app_user`)：
```bash
aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query SecretString --output text
```

#### 3.3 觸發輪換 (Trigger Rotation)
手動觸發立即輪換：
```bash
aws secretsmanager rotate-secret --secret-id $SECRET_NAME
```

#### 3.4 驗證交替結果
等待約 10-20 秒後，再次讀取 Secret，確認使用者名稱是否已自動切換為 **`app_user_clone`**：
```bash
aws secretsmanager get-secret-value --secret-id $SECRET_NAME --query SecretString --output text
```
> **預期結果**：您應該會看到 `"username": "app_user_clone"`。這證明了系統成功保留了舊使用者，並啟用了新使用者接手連線。

#### 3.5 (進階) 驗證舊憑證仍有效
為了確認零停機，您可以嘗試使用步驟 3.2 取得的「舊帳號密碼」連線資料庫。若輪換設計正確，舊帳號（在此例中為 `app_user`）此刻應該仍然可以登入。

## 驗證完成後的清理
驗證成功後，執行 terraform destroy可以清除已經建立的所有元件

## 架構補充說明：VPC Endpoints
本專案使用 **Interface Endpoint** (用於 Secrets Manager) 讓私有子網域內的 Lambda 能安全存取 AWS 服務。

### 補充：Gateway Endpoint (S3/DynamoDB)
S3 和 DynamoDB 雖也是 VPC 外部服務，但在私有存取時通常使用 **Gateway Endpoint**。

- **運作原理**：
  - 不使用 ENI 或 IP，而是透過修改 **Route Table**。
  - AWS 在路由表插入規則，將往 S3/DynamoDB 的流量 (透過 Prefix List 辨識) 導向 Endpoint (`vpce-id`)，直接走 AWS 骨幹網路。

- **原因**：
  - **歷史因素**：這兩者是早期服務，早於 PrivateLink 技術。
  - **成本與效能**：S3 常有大流量傳輸。Gateway Endpoint **免費** 且頻寬幾乎無限制，優於需付費且有頻寬限制的 Interface Endpoint。
