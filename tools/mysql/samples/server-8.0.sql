-- The server's own objects MySQL 8.0 and later add (loaded after server.sql): roles, a role granted with its admin
-- option and made a default role, dynamic privileges, account policies 8.0 added, a spatial reference system, a
-- resource group and a component.
CREATE ROLE 'reader', 'writer';
GRANT SELECT ON shop.* TO 'reader';
GRANT INSERT, UPDATE ON shop.* TO 'writer';
GRANT 'reader' TO 'app'@'%';
GRANT 'writer' TO 'app'@'%' WITH ADMIN OPTION;
SET DEFAULT ROLE 'reader' TO 'app'@'%';
GRANT BACKUP_ADMIN, SYSTEM_VARIABLES_ADMIN ON *.* TO 'report'@'10.0.%';
CREATE USER 'ops'@'localhost' IDENTIFIED BY 'not-kept-3' PASSWORD HISTORY 5 PASSWORD REUSE INTERVAL 365 DAY FAILED_LOGIN_ATTEMPTS 3 PASSWORD_LOCK_TIME 2 ATTRIBUTE '{"team": "shop"}';

CREATE SPATIAL REFERENCE SYSTEM 1000001 NAME 'shop_grid' ORGANIZATION 'shop' IDENTIFIED BY 1 DEFINITION 'GEOGCS["WGS 84",DATUM["World Geodetic System 1984",SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.017453292519943278,AUTHORITY["EPSG","9122"]],AXIS["Lat",NORTH],AXIS["Lon",EAST],AUTHORITY["EPSG","4326"]]' DESCRIPTION 'the shop''s grid';

CREATE RESOURCE GROUP rg_batch TYPE = USER VCPU = 0 THREAD_PRIORITY = 0 DISABLE;

INSTALL COMPONENT 'file://component_validate_password';
