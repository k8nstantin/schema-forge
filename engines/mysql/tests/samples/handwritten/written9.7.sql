-- MySQL 9.7 schema, written by Schema Forge
SET FOREIGN_KEY_CHECKS = 0;

CREATE DATABASE `lab`;
USE `lab`;

DELIMITER ;;
CREATE LIBRARY `text_tools`
    LANGUAGE JAVASCRIPT
    COMMENT 'Small text helpers'
AS $$
  export function slug(s) { return s.toLowerCase().replace(/[^a-z0-9]+/g, '-'); } // it's "fine"; really
$$ ;;
DELIMITER ;

DELIMITER ;;
CREATE FUNCTION `slug`(`s` varchar(200)) RETURNS varchar(200) CHARSET utf8mb4
    LANGUAGE JAVASCRIPT
    DETERMINISTIC
    USING (text_tools)
AS $$ return text_tools.slug(s); $$ ;;
DELIMITER ;

CREATE AGGREGATE FUNCTION `median` RETURNS REAL SONAME 'udf_median.so';

CREATE TABLE `notes` (
  `id` bigint NOT NULL,
  `title` varchar(200) NOT NULL,
  PRIMARY KEY (`id`)
);

CREATE TABLE `tags` (
  `note_id` bigint NOT NULL REFERENCES `notes` (`id`) ON DELETE CASCADE,
  `tag` varchar(40) NOT NULL,
  PRIMARY KEY (`note_id`,`tag`)
);

DELIMITER ;;
CREATE PROCEDURE `tag_note`(IN `p_note` bigint, IN `p_tag` varchar(40))
BEGIN
  INSERT INTO tags VALUES (p_note, p_tag);
END ;;
DELIMITER ;

SET FOREIGN_KEY_CHECKS = 1;
