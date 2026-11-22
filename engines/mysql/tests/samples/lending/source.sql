-- A made-up lending library, laced with stored programs: tables with keys, checks and foreign keys, procedures and
-- functions, triggers before and after each change, events on schedules, and views. Loaded into MySQL in Docker by
-- tests/live.rs (`lending`), and read back every way the engine reads.

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

INSERT INTO members (email, full_name, joined) VALUES ('ada@example.org', 'Ada', '2026-01-02');
INSERT INTO books (isbn, title, author, published, copies, available) VALUES ('9780000000001', 'On Engines', 'B. Babbage', 1994, 2, 2);
CALL borrow(1, '9780000000001', @loan);
CALL give_back(@loan);
