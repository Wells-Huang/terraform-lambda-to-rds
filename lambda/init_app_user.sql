-- Create the application user
-- Note: The password here should match the initial password configured in Terraform (aws_secretsmanager_secret_version.app_db_credentials_version)
-- After the first rotation, this password will no longer be valid, and the application should retrieve the password from Secrets Manager.
CREATE USER app_user WITH PASSWORD 'InitialPassword123!';

-- Grant connection permissions
GRANT CONNECT ON DATABASE postgres TO app_user;

-- Grant usage on public schema
GRANT USAGE ON SCHEMA public TO app_user;

-- Grant select permissions on all tables in public schema
-- You may want to refine these permissions based on your specific security requirements
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_user;

-- Optional: Ensure future tables are also readable
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_user;
