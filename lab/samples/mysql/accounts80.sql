-- Roles, MySQL 8.0 and later: a role with grants of its own, granted to an account with the right to grant it on, and
-- made that account's default role.
CREATE ROLE 'lab_reader';
GRANT SELECT ON shop.* TO 'lab_reader';
GRANT 'lab_reader' TO 'lab_app'@'%' WITH ADMIN OPTION;
SET DEFAULT ROLE 'lab_reader' TO 'lab_app'@'%';
