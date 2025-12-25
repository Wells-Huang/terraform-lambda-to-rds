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

