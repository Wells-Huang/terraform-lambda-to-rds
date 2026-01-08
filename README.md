## 專案簡介
利用Terraform透過main.tf部署Lambda, RDS database (Postgress), 以及相關元件
接著透過aws指令或Lambda test function確認Lambda與資料庫的連接成功

## 2026-01-08 重大更新：資料庫憑證自動輪換 (Credential Rotation)

本專案已實作 AWS Secrets Manager 自動輪換功能，以提升資料庫安全性。

### 1. 更新概要
*   **Admin User (RDS 擁有者)**：啟用單一使用者輪換 (Single User Rotation)。Secrets Manager 會直接修改 Admin 的密碼。
*   **App User (應用程式使用者)**：啟用多使用者輪換 (Multi User Rotation)。
    *   新增 `app_user` 專用 Secret (`app-db-credentials`)。
    *   Rotation Lambda 使用 Admin 憑證 (Master Secret) 登入，並修改 `app_user` 的密碼。
    *   應用程式 (`RDSAccessor`) 改為讀取 `app-db-credentials` 來連線。
*   **基礎設施變更**：
    *   新增 `RDSAdmin` Lambda：用於在私有子網內執行 SQL 初始化腳本。
    *   新增 `postgres-rotation` Lambda：自訂 Python 腳本執行密碼輪換邏輯。
    *   解開 Terraform 資源間的循環依賴 (DB vs Secret)。

### 2. 部署與初始化步驟

在 wsl 環境下：

1.  **部署資源**
    ```bash
    terraform init
    terraform apply -var="db_password=YOUR_INITIAL_PASSWORD"
    ```

2.  **【關鍵步驟】初始化應用程式使用者**
    由於 Terraform 無法直接登入資料庫建立使用者，部署後必須手動執行一次初始化指令。
    此指令會呼叫 `RDSAdmin` Lambda 執行 `sql/init_app_user.sql`，建立 `app_user` 並賦予連線權限。

    ```bash
    aws lambda invoke --function-name RDSAdmin --payload '{"sql_file": "init_app_user.sql"}' --cli-binary-format raw-in-base64-out response_init.json
    ```
    *檢查 `response_init.json` 確認回傳 "Successfully executed..."*

### 3. 驗證步驟

#### 3.1 驗證應用程式連線
確認 `RDSAccessor` 能使用新的 `app_user` 憑證連線：
```bash
aws lambda invoke --function-name RDSAccessor response_test.json
cat response_test.json
```

#### 3.2 驗證憑證輪換 (Credential Rotation)

**取得 Secret 名稱**：
```bash
aws secretsmanager list-secrets --query "SecretList[*].Name" --output table | grep credentials
```
(記下 `rds-credentials-xxxx` 和 `app-db-credentials-xxxx` 的完整名稱)

**測試 Admin 輪換**：
```bash
aws secretsmanager rotate-secret --secret-id <Admin_Secret_Name>
```

**測試 App User 輪換**：
```bash
aws secretsmanager rotate-secret --secret-id <App_User_Secret_Name>
```

**檢查輪換狀態**：
```bash
aws secretsmanager describe-secret --secret-id <Secret_Name>
```
確認 `LastRotatedDate` 已更新至最新時間。

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
