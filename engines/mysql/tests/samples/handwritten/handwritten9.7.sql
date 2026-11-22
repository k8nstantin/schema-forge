-- Server version 9.7
-- Hand-written MySQL 9.7 DDL: a JavaScript library and the routines that use it, a loadable function, and a
-- foreign key written on its column, which MySQL enforces from 9.0.
CREATE DATABASE lab;
USE lab;

CREATE LIBRARY IF NOT EXISTS text_tools LANGUAGE JAVASCRIPT COMMENT 'Small text helpers'
AS $$
  export function slug(s) { return s.toLowerCase().replace(/[^a-z0-9]+/g, '-'); } // it's "fine"; really
$$;

CREATE FUNCTION slug(s varchar(200)) RETURNS varchar(200) CHARSET utf8mb4 DETERMINISTIC LANGUAGE JAVASCRIPT
  USING (text_tools)
AS $$ return text_tools.slug(s); $$;

CREATE AGGREGATE FUNCTION median RETURNS REAL SONAME 'udf_median.so';

CREATE TABLE notes (
  id bigint NOT NULL PRIMARY KEY,
  title varchar(200) NOT NULL
);
CREATE TABLE tags (
  note_id bigint NOT NULL REFERENCES notes (id) ON DELETE CASCADE,
  tag varchar(40) NOT NULL,
  PRIMARY KEY (note_id, tag)
);

DELIMITER //
CREATE PROCEDURE tag_note(IN p_note bigint, IN p_tag varchar(40))
BEGIN
  INSERT INTO tags VALUES (p_note, p_tag);
END //
DELIMITER ;
