-- Each order as it is now.
CREATE VIEW `lake`.`shop`.`current_orders` AS
SELECT order_no, customer_id, total FROM `lake`.`shop`.`orders` WHERE valid_to IS NULL;
