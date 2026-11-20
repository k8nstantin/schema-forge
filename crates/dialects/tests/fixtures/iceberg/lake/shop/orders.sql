-- lake.shop.orders
-- Every version of every order, from the orders service through Debezium.
--
-- Merge-on-read: updates arrive all day.
CREATE TABLE IF NOT EXISTS `lake`.`shop`.`orders` (
  `order_key` BIGINT NOT NULL COMMENT 'surrogate key',
  `order_no` STRING NOT NULL COMMENT 'the business key',
  `customer_id` BIGINT NOT NULL,
  `total` DECIMAL(12,2) NOT NULL COMMENT 'the order\'s total, tax included',
  `lines` ARRAY<STRUCT<`sku`: STRING NOT NULL, `qty`: INT, `price`: DECIMAL(12,2) COMMENT 'unit price'>> COMMENT 'one entry per line',
  `attributes` MAP<STRING, STRING>,
  `shipped_to` STRUCT<`city`: STRING, `postcode`: STRING>,
  `valid_from` TIMESTAMP NOT NULL,
  `valid_to` TIMESTAMP,
  `loaded_at` TIMESTAMP_NTZ
)
USING iceberg
PARTITIONED BY (month(`valid_from`), bucket(16, `customer_id`), truncate(4, `order_no`))
COMMENT 'Every version of every order.'
TBLPROPERTIES (
  'format-version' = '3',
  'write.delete.mode' = 'merge-on-read',
  'write.update.mode' = 'merge-on-read',
  'write.merge.mode' = 'merge-on-read'
);
ALTER TABLE `lake`.`shop`.`orders` WRITE ORDERED BY (`order_no` ASC, `valid_from` DESC NULLS FIRST);
ALTER TABLE `lake`.`shop`.`orders` SET IDENTIFIER FIELDS `order_key`;
