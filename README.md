## 專案簡介
利用Terraform透過main.tf部署Lambda, RDS database (Postgress), 以及相關元件
接著透過aws指令或Lambda test function確認Lambda與資料庫的連接成功

## 使用說明
在wsl環境下
1. 執行terraform init
2. 執行terraform apply -var="db_password=YOUR_INITIAL_PASSWORD"
執行成功後, terminal顯示 Lambda名稱, RDS_endpoint及secret name 

## 驗證步驟:
terraform apply執行完畢後, 
執行 aws lambda invoke --function-name "LAMBDA NAME" output.txt
如顯示
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
沒有錯誤訊息, 表示執行成功
或者進入AWS console, 在對應的Lamdba內, Code區域輸入{}後執行測試
如果回傳成功 (status code=200, body= Successfully connected! ....) 即表示Lambda連接上RDS DB.

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

