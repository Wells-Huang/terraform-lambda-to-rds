import boto3
import json
import logging
import os
import psycopg2
import base64

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def get_secret(secret_name, region_name):
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
        logger.error(f"Error retrieving secret: {e}")
        raise e
    else:
        if 'SecretString' in get_secret_value_response:
            secret = get_secret_value_response['SecretString']
            return json.loads(secret)
        else:
            decoded_binary_secret = base64.b64decode(get_secret_value_response['SecretBinary'])
            return json.loads(decoded_binary_secret)

def lambda_handler(event, context):
    """
    Executes SQL commands on the RDS instance.
    Payload format:
    {
        "sql_file": "init_app_user.sql"  # Optional, defaults to this
    }
    """
    try:
        secret_name = os.environ['SECRET_NAME']
        region_name = os.environ.get('AWS_REGION', 'ap-northeast-1')
        
        # 1. Get Credentials
        creds = get_secret(secret_name, region_name)
        
        # 2. Connect to DB
        logger.info("Connecting to database...")
        conn = psycopg2.connect(
            host=creds['host'],
            database=creds.get('dbname', 'postgres'),
            user=creds['username'],
            password=creds['password'],
            port=creds.get('port', 5432),
            connect_timeout=5
        )
        conn.autocommit = True 
        
        # 3. Read SQL File
        file_name = event.get('sql_file', 'init_app_user.sql')
        # Assuming the file is at the root of the lambda task because we zipped the lambda/ folder content
        # Note: terraform archive_file source_dir="${path.module}/lambda" means contents of lambda/ are at root of zip.
        # But wait, init_app_user.sql is in `sql/` directory in the project structure.
        # We need to make sure it's included in the zip or we read it raw here.
        
        # STRATEGY CHANGE: 
        # Instead of relying on file path which might be tricky with `archive_file` structure if not moved,
        # I will just Embed the critical SQL here for `init_app_user` for simplicity 
        # OR assume the user will manually invoke with SQL string? 
        # No, user wants to run the specific file.
        # Let's read the file. I will assume I will move the file to `lambda/` via Terraform or I just write a copy there now.
        
        sql_content = ""
        # Try to find the file provided in the package
        if os.path.exists(file_name):
            with open(file_name, 'r') as f:
                sql_content = f.read()
        else:
            # Fallback or Error
            return {
                'statusCode': 400,
                'body': json.dumps(f"SQL file {file_name} not found in Lambda package.")
            }

        logger.info(f"Executing SQL from {file_name}...")
        
        # 4. Execute
        with conn.cursor() as cur:
            cur.execute(sql_content)
            
        conn.close()
        
        return {
            'statusCode': 200,
            'body': json.dumps(f"Successfully executed {file_name}")
        }

    except Exception as e:
        logger.error(f"Execution failed: {e}")
        return {
            'statusCode': 500,
            'body': json.dumps(f"Error: {str(e)}")
        }
