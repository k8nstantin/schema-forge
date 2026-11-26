-- An event a replica keeps switched off. MySQL 8.4 and later write it DISABLE ON REPLICA; 5.7 and 8.0 know it only as
-- DISABLE ON SLAVE, and lab/setup.py writes it so for them.
DELIMITER //
CREATE EVENT features.e_replica_off ON SCHEDULE EVERY 1 HOUR STARTS '2030-01-01 00:00:00' ON COMPLETION NOT PRESERVE DISABLE ON REPLICA
  DO DELETE FROM features.myisam_log WHERE id < -1//
DELIMITER ;
