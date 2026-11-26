-- What MySQL 5.7 takes and 8.0 does not, for the upgrade check: a word 8.0 reserves used bare in a routine, the query
-- cache's hint, a GROUP BY that sorts, and a function 8.0 removed (which no server refuses until the routine runs).
CREATE TABLE features.ranks (id INT PRIMARY KEY, `rank` INT NOT NULL);
DELIMITER //
CREATE PROCEDURE features.p_top() READS SQL DATA SELECT id, rank FROM features.ranks ORDER BY rank//
CREATE PROCEDURE features.p_cached() READS SQL DATA SELECT SQL_CACHE id FROM features.ranks//
CREATE FUNCTION features.f_hash(p VARCHAR(40)) RETURNS VARCHAR(41) DETERMINISTIC NO SQL RETURN PASSWORD(p)//
DELIMITER ;
CREATE VIEW features.v_grouped AS SELECT id FROM features.ranks GROUP BY id DESC;
