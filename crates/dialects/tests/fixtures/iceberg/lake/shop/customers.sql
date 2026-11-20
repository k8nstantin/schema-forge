CREATE TABLE `lake`.`shop`.`customers` (
  `id` BIGINT NOT NULL,
  `email` STRING NOT NULL COMMENT 'lowercased',
  `signed_up_on` DATE
)
USING iceberg
PARTITIONED BY (`signed_up_on`)
TBLPROPERTIES (
  'format-version' = '2'
);
