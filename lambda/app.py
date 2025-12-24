import os
import boto3
import json
import psycopg2

def get_secret():
    """從 AWS Secrets Manager 獲取資料庫憑證"""
    secret_name = os.environ['SECRET_NAME']
    # 確保 region 與您的 Terraform 設定一致
    region_name = os.environ.get('AWS_REGION', 'ap-northeast-1') 

    session = boto3.session.Session()
    client = session.client(
        service_name='secretsmanager',
        region_name=region_name
    )

    try:
        get_secret_value_response = client.get_secret_value(
            SecretId=secret_name
        )
    except Exception as e:
        print(f"Error retrieving secret: {e}")
        raise e
    else:
        if 'SecretString' in get_secret_value_response:
            secret = get_secret_value_response['SecretString']
            return json.loads(secret)
        else:
            # 處理二進位 secret 的情況
            decoded_binary_secret = base64.b64decode(get_secret_value_response['SecretBinary'])
            return json.loads(decoded_binary_secret)

def lambda_handler(event, context):
    """Lambda 執行進入點"""
    try:
        # 獲取憑證
        creds = get_secret()
        db_host = os.environ['DB_HOST']
        db_name = os.environ['DB_NAME']
        
        print("Attempting to connect to the database...")
        # 連線到 RDS
        conn = psycopg2.connect(
            host=db_host,
            database=db_name,
            user=creds['username'],
            password=creds['password'],
            port=5432, # PostgreSQL 預設 port
            connect_timeout=5
        )
        
        cursor = conn.cursor()
        
        # 執行一個簡單的查詢
        print("Executing a simple query...")
        cursor.execute("SELECT version();")
        db_version = cursor.fetchone()
        
        print(f"Successfully connected to database. Version: {db_version}")
        
        cursor.close()
        conn.close()
        
        return {
            'statusCode': 200,
            'body': json.dumps(f"Successfully connected! DB Version: {db_version}")
        }

    except Exception as e:
        print(f"Database connection failed: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"An error occurred: {str(e)}")
        }

