-- A made-up lending library, laced with stored programs and holding every type MySQL has: tables with keys, checks,
-- foreign keys and partitions; a table for each family of types (whole numbers, exact and approximate numbers, text,
-- bytes, dates and times, lists, JSON, bit strings, every spatial type); procedures and functions; triggers before and
-- after each change; events on schedules; views. Loaded into MySQL in Docker by tests/live.rs (`lending`), and read
-- back every way the engine reads; source97.sql adds what came after 8.4.

CREATE DATABASE lending DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE lending;

CREATE TABLE members (
  id int unsigned NOT NULL AUTO_INCREMENT,
  email varchar(255) NOT NULL,
  full_name varchar(200) NOT NULL,
  joined date NOT NULL,
  status enum('active','suspended','left') NOT NULL DEFAULT 'active',
  fines decimal(8,2) NOT NULL DEFAULT '0.00',
  loans_out smallint unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (id),
  UNIQUE KEY members_email (email),
  CONSTRAINT members_fines_positive CHECK (fines >= 0)
) ENGINE=InnoDB COMMENT='Who may borrow';

CREATE TABLE books (
  isbn char(13) NOT NULL,
  title varchar(300) NOT NULL,
  author varchar(200) NOT NULL,
  published year DEFAULT NULL,
  copies tinyint unsigned NOT NULL DEFAULT 1,
  available tinyint unsigned NOT NULL DEFAULT 1,
  PRIMARY KEY (isbn),
  KEY books_author (author),
  FULLTEXT KEY books_title_text (title),
  CONSTRAINT books_available_le_copies CHECK (available <= copies)
) ENGINE=InnoDB;

CREATE TABLE loans (
  id bigint unsigned NOT NULL AUTO_INCREMENT,
  member_id int unsigned NOT NULL,
  isbn char(13) NOT NULL,
  borrowed datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  due date NOT NULL,
  returned datetime DEFAULT NULL,
  overdue_days int GENERATED ALWAYS AS (datediff(returned, due)) VIRTUAL,
  PRIMARY KEY (id),
  KEY loans_open (member_id, returned),
  CONSTRAINT loans_member FOREIGN KEY (member_id) REFERENCES members (id) ON DELETE RESTRICT,
  CONSTRAINT loans_book FOREIGN KEY (isbn) REFERENCES books (isbn) ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE audit (
  id bigint unsigned NOT NULL AUTO_INCREMENT,
  at timestamp(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  what varchar(40) NOT NULL,
  detail json DEFAULT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE branches (
  id smallint unsigned NOT NULL AUTO_INCREMENT,
  name varchar(100) NOT NULL,
  location point NOT NULL SRID 4326,
  catchment polygon DEFAULT NULL,
  opened date NOT NULL,
  phone varchar(30) DEFAULT NULL,
  PRIMARY KEY (id),
  UNIQUE KEY branches_name (name),
  SPATIAL KEY branches_location (location)
) ENGINE=InnoDB COMMENT='Where the books are';

CREATE TABLE shelves (
  id int unsigned NOT NULL AUTO_INCREMENT,
  branch_id smallint unsigned NOT NULL,
  outline geometry DEFAULT NULL,
  route linestring DEFAULT NULL,
  lamps multipoint DEFAULT NULL,
  aisles multilinestring DEFAULT NULL,
  zones multipolygon DEFAULT NULL,
  fixtures geomcollection DEFAULT NULL,
  PRIMARY KEY (id),
  CONSTRAINT shelves_branch FOREIGN KEY (branch_id) REFERENCES branches (id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE counters (
  id int NOT NULL AUTO_INCREMENT,
  t tinyint DEFAULT NULL,
  tu tinyint unsigned DEFAULT NULL,
  s smallint DEFAULT -32768,
  su smallint unsigned DEFAULT NULL,
  m mediumint DEFAULT NULL,
  mu mediumint unsigned DEFAULT NULL,
  i int DEFAULT NULL,
  iu int unsigned DEFAULT NULL,
  b bigint DEFAULT NULL,
  bu bigint unsigned DEFAULT NULL,
  flag boolean NOT NULL DEFAULT FALSE,
  bits bit(16) DEFAULT b'0000000000000001',
  legacy int(8) unsigned zerofill DEFAULT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB COMMENT='Every whole number';

CREATE TABLE measures (
  id int NOT NULL AUTO_INCREMENT,
  money decimal(19,4) NOT NULL DEFAULT '0.0000',
  widest decimal(65,30) DEFAULT NULL,
  whole numeric(5) DEFAULT NULL,
  ratio float DEFAULT NULL,
  precise double DEFAULT NULL,
  real_number real DEFAULT NULL,
  PRIMARY KEY (id),
  CONSTRAINT measures_ratio CHECK (ratio BETWEEN 0 AND 1)
) ENGINE=InnoDB COMMENT='Every exact and approximate number';

CREATE TABLE texts (
  id int NOT NULL AUTO_INCREMENT,
  code char(1) NOT NULL DEFAULT 'a',
  padded char(255) DEFAULT NULL,
  short varchar(1000) DEFAULT NULL,
  latin varchar(50) CHARACTER SET latin1 COLLATE latin1_swedish_ci DEFAULT NULL,
  tiny tinytext,
  body text,
  medium mediumtext,
  huge longtext,
  PRIMARY KEY (id),
  KEY texts_short (short(40)),
  FULLTEXT KEY texts_body (body)
) ENGINE=InnoDB COMMENT='Every text';

CREATE TABLE media (
  id int NOT NULL AUTO_INCREMENT,
  checksum binary(32) DEFAULT NULL,
  thumbnail varbinary(255) DEFAULT NULL,
  icon tinyblob,
  scan blob,
  audio mediumblob,
  video longblob,
  PRIMARY KEY (id),
  UNIQUE KEY media_checksum (checksum)
) ENGINE=InnoDB COMMENT='Every kind of bytes';

CREATE TABLE schedule (
  id int NOT NULL AUTO_INCREMENT,
  day date NOT NULL,
  opens time NOT NULL DEFAULT '09:00:00',
  closes time(6) DEFAULT NULL,
  noted datetime DEFAULT NULL,
  noted_ms datetime(3) DEFAULT NULL,
  stamped timestamp NULL DEFAULT NULL,
  stamped_us timestamp(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  season year DEFAULT NULL,
  PRIMARY KEY (id),
  KEY schedule_day (day DESC)
) ENGINE=InnoDB COMMENT='Every date and time';

CREATE TABLE preferences (
  member_id int unsigned NOT NULL,
  contact enum('email','post','none') NOT NULL DEFAULT 'email',
  genres set('fiction','history','science','poetry') DEFAULT NULL,
  settings json DEFAULT NULL,
  language varchar(8) GENERATED ALWAYS AS (json_unquote(json_extract(settings, '$.language'))) STORED,
  PRIMARY KEY (member_id),
  KEY preferences_language (language),
  CONSTRAINT preferences_member FOREIGN KEY (member_id) REFERENCES members (id) ON DELETE CASCADE
) ENGINE=InnoDB COMMENT='Lists of values, and JSON';

CREATE TABLE book_tags (
  isbn char(13) NOT NULL,
  tag varchar(40) NOT NULL,
  added timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (isbn, tag),
  KEY book_tags_tag (tag),
  CONSTRAINT book_tags_book FOREIGN KEY (isbn) REFERENCES books (isbn) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE visits (
  branch_id smallint unsigned NOT NULL,
  visited date NOT NULL,
  people int unsigned NOT NULL DEFAULT 0,
  PRIMARY KEY (branch_id, visited)
) ENGINE=InnoDB
PARTITION BY LIST (branch_id) (
  PARTITION north VALUES IN (1, 2),
  PARTITION south VALUES IN (3, 4),
  PARTITION other VALUES IN (5, 6, 7, 8)
);

CREATE TABLE archive (
  id bigint unsigned NOT NULL,
  closed date NOT NULL,
  payload json DEFAULT NULL,
  PRIMARY KEY (id, closed)
) ENGINE=InnoDB
PARTITION BY RANGE COLUMNS (closed) (
  PARTITION before_2026 VALUES LESS THAN ('2026-01-01'),
  PARTITION y2026 VALUES LESS THAN ('2027-01-01'),
  PARTITION later VALUES LESS THAN (MAXVALUE)
);

DELIMITER ;;
CREATE FUNCTION fine_for(days int) RETURNS decimal(8,2)
  DETERMINISTIC NO SQL
  COMMENT 'Twenty cents a day, at most ten'
RETURN LEAST(GREATEST(days, 0) * 0.20, 10.00);;

CREATE FUNCTION can_borrow(p_member int unsigned) RETURNS tinyint(1)
  READS SQL DATA
BEGIN
  DECLARE ok tinyint(1);
  SELECT status = 'active' AND fines < 5 AND loans_out < 5 INTO ok FROM members WHERE id = p_member;
  RETURN COALESCE(ok, 0);
END;;

CREATE PROCEDURE borrow(IN p_member int unsigned, IN p_isbn char(13), OUT p_loan bigint unsigned)
  MODIFIES SQL DATA
  COMMENT 'Lends a copy for two weeks'
BEGIN
  IF NOT can_borrow(p_member) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'this member may not borrow';
  END IF;
  INSERT INTO loans (member_id, isbn, due) VALUES (p_member, p_isbn, CURDATE() + INTERVAL 14 DAY);
  SET p_loan = LAST_INSERT_ID();
END;;

CREATE PROCEDURE give_back(IN p_loan bigint unsigned)
  MODIFIES SQL DATA
  SQL SECURITY INVOKER
BEGIN
  UPDATE loans SET returned = NOW() WHERE id = p_loan AND returned IS NULL;
END;;

CREATE FUNCTION member_label(p_member int unsigned) RETURNS varchar(260) CHARSET utf8mb4
  READS SQL DATA
  SQL SECURITY INVOKER
BEGIN
  DECLARE label varchar(260);
  SELECT CONCAT(full_name, ' <', email, '>') INTO label FROM members WHERE id = p_member;
  RETURN label;
END;;

CREATE FUNCTION days_between(a date, b date) RETURNS int
  DETERMINISTIC NO SQL
RETURN DATEDIFF(b, a);;

CREATE PROCEDURE renew(IN p_loan bigint unsigned, INOUT p_days int)
  MODIFIES SQL DATA
  COMMENT 'Pushes the due date out, at most two weeks'
BEGIN
  SET p_days = LEAST(GREATEST(p_days, 1), 14);
  UPDATE loans SET due = due + INTERVAL p_days DAY WHERE id = p_loan AND returned IS NULL;
END;;

CREATE PROCEDURE pay_fine(IN p_member int unsigned, IN p_amount decimal(8,2))
  MODIFIES SQL DATA
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION
  BEGIN
    ROLLBACK;
    RESIGNAL;
  END;
  START TRANSACTION;
  UPDATE members SET fines = GREATEST(fines - p_amount, 0) WHERE id = p_member;
  INSERT INTO audit (what, detail) VALUES ('fine paid', JSON_OBJECT('member', p_member, 'amount', p_amount));
  COMMIT;
END;;

CREATE PROCEDURE branch_report(IN p_branch smallint unsigned)
  READS SQL DATA
BEGIN
  DECLARE done int DEFAULT 0;
  DECLARE v_day date;
  DECLARE v_people int;
  DECLARE days CURSOR FOR SELECT visited, people FROM visits WHERE branch_id = p_branch ORDER BY visited;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;
  OPEN days;
  read_loop: LOOP
    FETCH days INTO v_day, v_people;
    IF done THEN
      LEAVE read_loop;
    END IF;
  END LOOP;
  CLOSE days;
  SELECT p_branch AS branch, COUNT(*) AS days FROM visits WHERE branch_id = p_branch;
END;;

CREATE TRIGGER loans_before_insert BEFORE INSERT ON loans FOR EACH ROW
BEGIN
  IF (SELECT available FROM books WHERE isbn = NEW.isbn) = 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'no copy is available';
  END IF;
END;;

CREATE TRIGGER loans_after_insert AFTER INSERT ON loans FOR EACH ROW
BEGIN
  UPDATE books SET available = available - 1 WHERE isbn = NEW.isbn;
  UPDATE members SET loans_out = loans_out + 1 WHERE id = NEW.member_id;
END;;

CREATE TRIGGER loans_after_return AFTER UPDATE ON loans FOR EACH ROW
BEGIN
  IF OLD.returned IS NULL AND NEW.returned IS NOT NULL THEN
    UPDATE books SET available = available + 1 WHERE isbn = NEW.isbn;
    UPDATE members SET loans_out = loans_out - 1,
      fines = fines + fine_for(DATEDIFF(NEW.returned, NEW.due)) WHERE id = NEW.member_id;
  END IF;
END;;

CREATE TRIGGER loans_audit AFTER UPDATE ON loans FOR EACH ROW FOLLOWS loans_after_return
  INSERT INTO audit (what, detail) VALUES ('loan changed', JSON_OBJECT('loan', NEW.id));;

CREATE TRIGGER members_before_delete BEFORE DELETE ON members FOR EACH ROW
  INSERT INTO audit (what, detail) VALUES ('member removed', JSON_OBJECT('id', OLD.id, 'email', OLD.email));;

CREATE TRIGGER members_before_insert BEFORE INSERT ON members FOR EACH ROW
  SET NEW.email = LOWER(TRIM(NEW.email));;

CREATE TRIGGER members_before_update BEFORE UPDATE ON members FOR EACH ROW
BEGIN
  SET NEW.email = LOWER(TRIM(NEW.email));
  IF NEW.fines > 50 THEN
    SET NEW.status = 'suspended';
  END IF;
END;;

CREATE TRIGGER books_before_update BEFORE UPDATE ON books FOR EACH ROW
BEGIN
  IF NEW.available > NEW.copies THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'more available than copies';
  END IF;
END;;

CREATE TRIGGER book_tags_after_insert AFTER INSERT ON book_tags FOR EACH ROW
  INSERT INTO audit (what, detail) VALUES ('tagged', JSON_OBJECT('isbn', NEW.isbn, 'tag', NEW.tag));;

CREATE TRIGGER visits_before_insert BEFORE INSERT ON visits FOR EACH ROW
  SET NEW.people = GREATEST(NEW.people, 0);;

CREATE EVENT count_visits ON SCHEDULE EVERY 1 HOUR STARTS '2027-01-01 00:00:00'
  DISABLE ON REPLICA
  COMMENT 'Opens today''s visit rows'
  DO INSERT IGNORE INTO visits (branch_id, visited) SELECT id, CURDATE() FROM branches;;

CREATE EVENT suspend_overdue ON SCHEDULE EVERY 1 DAY STARTS '2027-01-01 02:00:00'
  ON COMPLETION PRESERVE
  COMMENT 'Suspends members with a loan a month overdue'
  DO UPDATE members m JOIN loans l ON l.member_id = m.id
     SET m.status = 'suspended' WHERE l.returned IS NULL AND l.due < CURDATE() - INTERVAL 30 DAY;;

CREATE EVENT trim_audit ON SCHEDULE EVERY 1 WEEK STARTS '2027-01-03 04:00:00' ENDS '2030-01-01 00:00:00'
  DISABLE
  DO DELETE FROM audit WHERE at < NOW() - INTERVAL 1 YEAR;;

CREATE EVENT launch_note ON SCHEDULE AT '2031-01-01 00:00:00'
  DO INSERT INTO audit (what) VALUES ('library opened');;
DELIMITER ;

CREATE VIEW open_loans AS
  SELECT l.id, m.full_name, b.title, l.due, l.overdue_days FROM loans l
  JOIN members m ON m.id = l.member_id JOIN books b ON b.isbn = l.isbn WHERE l.returned IS NULL;

CREATE ALGORITHM=TEMPTABLE SQL SECURITY INVOKER VIEW overdue_members (member, loans, worst) AS
  SELECT full_name, COUNT(*), MAX(overdue_days) FROM open_loans WHERE overdue_days > 0 GROUP BY full_name;

CREATE VIEW branch_shelves AS
  SELECT b.id, b.name, COUNT(s.id) AS shelves FROM branches b LEFT JOIN shelves s ON s.branch_id = b.id GROUP BY b.id, b.name;

CREATE ALGORITHM=MERGE VIEW lendable_books AS
  SELECT isbn, title, author, copies, available FROM books WHERE available > 0 WITH LOCAL CHECK OPTION;

CREATE VIEW member_preferences AS
  WITH tagged AS (SELECT member_id, contact, genres FROM preferences)
  SELECT m.id, m.full_name, t.contact, t.genres FROM members m LEFT JOIN tagged t ON t.member_id = m.id;

INSERT INTO members (email, full_name, joined) VALUES ('ada@example.org', 'Ada', '2026-01-02');
INSERT INTO books (isbn, title, author, published, copies, available) VALUES ('9780000000001', 'On Engines', 'B. Babbage', 1994, 2, 2);
CALL borrow(1, '9780000000001', @loan);
CALL give_back(@loan);

INSERT INTO branches (name, location, catchment, opened) VALUES
  ('Central', ST_SRID(POINT(52.52, 13.40), 4326), ST_GeomFromText('POLYGON((0 0,1 0,1 1,0 1,0 0))'), '1999-05-01');
INSERT INTO shelves (branch_id, route, lamps) VALUES
  (1, ST_GeomFromText('LINESTRING(0 0,1 1)'), ST_GeomFromText('MULTIPOINT((0 0),(1 1))'));
INSERT INTO counters (t, tu, su, m, mu, i, iu, b, bu, flag, legacy) VALUES
  (-128, 255, 65535, -8388608, 16777215, -2147483648, 4294967295, -9223372036854775808, 18446744073709551615, TRUE, 42);
INSERT INTO measures (money, widest, whole, ratio, precise, real_number) VALUES (12.3456, 1.5, 99999, 0.5, 3.141592653589793, 2.5);
INSERT INTO texts (code, short, latin, body) VALUES ('z', 'a short text', 'Grüße', 'a body of text to search');
INSERT INTO media (checksum, thumbnail, scan) VALUES (UNHEX(SHA2('x', 256)), 0x0102, 'bytes');
INSERT INTO schedule (day, closes, noted, noted_ms, stamped, season) VALUES
  ('2026-11-22', '17:30:00.123456', '2026-11-22 10:00:00', '2026-11-22 10:00:00.250', '2026-11-22 10:00:00', 2026);
INSERT INTO preferences (member_id, genres, settings) VALUES (1, 'fiction,poetry', '{"language": "en"}');
INSERT INTO book_tags (isbn, tag) VALUES ('9780000000001', 'engines');
INSERT INTO visits (branch_id, visited, people) VALUES (1, '2026-11-22', 12);
INSERT INTO archive (id, closed) VALUES (1, '2025-12-31'), (2, '2026-06-01');
SET @days = 7;
CALL renew(@loan, @days);
CALL pay_fine(1, 1.00);
CALL branch_report(1);
