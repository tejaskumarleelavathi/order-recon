USE master;
GO

-- local sandbox, rebuilt from scratch on every run
IF DB_ID('OrderRecon') IS NOT NULL
BEGIN
    ALTER DATABASE OrderRecon SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE OrderRecon;
END
GO

CREATE DATABASE OrderRecon;
GO

ALTER DATABASE OrderRecon SET RECOVERY SIMPLE;
GO
