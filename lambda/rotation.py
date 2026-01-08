import boto3
import json
import logging
import os
import psycopg2
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def get_connection(secret_dict):
    """Establishes a connection to the database."""
    try:
        # Construct connection string or parameters
        # Adjust sslmode as needed, usually 'require' or 'prefer' for RDS
        conn = psycopg2.connect(
            host=secret_dict['host'],
            port=secret_dict.get('port', 5432),
            user=secret_dict['username'],
            password=secret_dict['password'],
            database=secret_dict.get('dbname', 'postgres'),
            connect_timeout=5,
            sslmode='require' 
        )
        return conn
    except Exception as e:
        logger.error(f"Connection failed: {e}")
        return None

def get_secret_dict(client, arn, stage, token=None):
    """Retrieves the secret dictionary from Secrets Manager."""
    params = {'SecretId': arn, 'VersionStage': stage}
    if token:
        params['VersionId'] = token
    
    response = client.get_secret_value(**params)
    
    if 'SecretString' in response:
        secret = response['SecretString']
        return json.loads(secret)
    else:
        # Binary secrets are not supported in this simple implementation
        raise ValueError("Binary secrets not supported.")

def handler_single(event, context):
    """Entry point for Single User Rotation."""
    return rotation_handler(event, context, strategy="single")

def handler_multi(event, context):
    """Entry point for Multi User Rotation."""
    return rotation_handler(event, context, strategy="multi")

def rotation_handler(event, context, strategy):
    arn = event['SecretId']
    token = event['ClientRequestToken']
    step = event['Step']
    
    client = boto3.client('secretsmanager', endpoint_url=os.environ.get('SECRETS_MANAGER_ENDPOINT'))
    
    # Check rotation enabled
    metadata = client.describe_secret(SecretId=arn)
    if not metadata.get('RotationEnabled'):
        raise ValueError(f"Secret {arn} is not enabled for rotation")
    
    versions = metadata['VersionIdsToStages']
    if token not in versions:
        raise ValueError(f"Secret version {token} has no stage for rotation of secret {arn}")
    
    if "AWSCURRENT" in versions[token]:
        logger.info(f"Secret version {token} already set as AWSCURRENT for secret {arn}.")
        return
    elif "AWSPENDING" not in versions[token]:
        raise ValueError(f"Secret version {token} not set as AWSPENDING for rotation of secret {arn}")

    if step == "createSecret":
        create_secret(client, arn, token)
    elif step == "setSecret":
        if strategy == "single":
            set_secret_single(client, arn, token)
        elif strategy == "multi":
            set_secret_multi(client, arn, token)
    elif step == "testSecret":
        test_secret(client, arn, token)
    elif step == "finishSecret":
        finish_secret(client, arn, token)
    else:
        raise ValueError(f"Invalid step parameter {step} for secret {arn}")

def create_secret(client, arn, token):
    """Creates the AWSPENDING secret if it doesn't exist."""
    # Ensure current exists
    get_secret_dict(client, arn, "AWSCURRENT")
    
    try:
        get_secret_dict(client, arn, "AWSPENDING", token)
        logger.info(f"createSecret: Successfully retrieved secret for {arn}.")
    except client.exceptions.ResourceNotFoundException:
        # Create new password
        # Get current dict to keep other fields (engine, host, etc.)
        current_dict = get_secret_dict(client, arn, "AWSCURRENT")
        
        # Exclude characters that might break connection strings
        passwd = client.get_random_password(
            ExcludeCharacters="/@\"'\\",
            PasswordLength=32,
            RequireEachIncludedType=True
        )['RandomPassword']
        
        current_dict['password'] = passwd
        
        client.put_secret_value(
            SecretId=arn,
            ClientRequestToken=token,
            SecretString=json.dumps(current_dict),
            VersionStages=['AWSPENDING']
        )
        logger.info(f"createSecret: Successfully put secret for ARN {arn} and version {token}.")

def set_secret_single(client, arn, token):
    """Single User: Modifies the user's password in DB."""
    current_dict = get_secret_dict(client, arn, "AWSCURRENT")
    pending_dict = get_secret_dict(client, arn, "AWSPENDING", token)
    
    # Check if pending works
    conn = get_connection(pending_dict)
    if conn:
        conn.close()
        logger.info(f"setSecret: AWSPENDING secret is already set as password.")
        return

    # Try connecting with Current
    conn = get_connection(current_dict)
    if not conn:
        # Try Previous if needed? For simplicity, we assume Current works.
        # Ideally, fetch AWSPREVIOUS and try that too.
        try:
            prev_dict = get_secret_dict(client, arn, "AWSPREVIOUS")
            conn = get_connection(prev_dict)
        except:
            pass
            
    if not conn:
        raise ValueError("Unable to log into database using current or previous credentials")

    # Change password
    try:
        with conn.cursor() as cur:
            # PostgreSQL: ALTER USER "username" WITH PASSWORD 'password';
            # Use sql parameters/formatting to avoid injection if possible, 
            # but standard psycopg2 param binding works for values, not identifiers.
            # We must be careful with username.
            safe_username = pending_dict['username'].replace('"', '""')
            query = f'ALTER USER "{safe_username}" WITH PASSWORD %s'
            cur.execute(query, (pending_dict['password'],))
            conn.commit()
            logger.info("Successfully changed password in DB.")
    finally:
        conn.close()

def set_secret_multi(client, arn, token):
    """Multi User: Uses Master secret to change App User password."""
    current_dict = get_secret_dict(client, arn, "AWSCURRENT")
    pending_dict = get_secret_dict(client, arn, "AWSPENDING", token)
    
    # 1. Check if pending works (App User with new password)
    conn = get_connection(pending_dict)
    if conn:
        conn.close()
        logger.info(f"setSecret: AWSPENDING secret is already set.")
        return

    # 2. Get Master Secret
    if 'masterarn' not in current_dict:
        raise ValueError("masterarn not found in secret for Multi User rotation")
    
    master_arn = current_dict['masterarn']
    master_dict = get_secret_dict(client, master_arn, "AWSCURRENT")
    
    # Connect as Master
    conn = get_connection(master_dict)
    if not conn:
        raise ValueError("Unable to log into database using Master credentials")

    # Change App User Password
    try:
        with conn.cursor() as cur:
            safe_username = pending_dict['username'].replace('"', '""')
            query = f'ALTER USER "{safe_username}" WITH PASSWORD %s'
            cur.execute(query, (pending_dict['password'],))
            conn.commit()
            logger.info("Successfully changed App User password using Master credentials.")
    finally:
        conn.close()

def test_secret(client, arn, token):
    """Tests the AWSPENDING secret."""
    pending_dict = get_secret_dict(client, arn, "AWSPENDING", token)
    conn = get_connection(pending_dict)
    if not conn:
        raise ValueError("testSecret: Unable to log into database with AWSPENDING secret")
    conn.close()
    logger.info("testSecret: Successfully logged in with AWSPENDING secret.")

def finish_secret(client, arn, token):
    """Finalizes rotation by moving AWSCURRENT to the new version."""
    metadata = client.describe_secret(SecretId=arn)
    current_version = metadata.get('VersionId')
    
    if current_version == token:
        logger.info(f"finishSecret: Version {token} is already AWSCURRENT.")
        return
        
    client.update_secret_version_stage(
        SecretId=arn,
        VersionStage="AWSCURRENT",
        MoveToVersionId=token,
        RemoveFromVersionId=current_version
    )
    logger.info(f"finishSecret: Successfully moved AWSCURRENT to version {token}.")
