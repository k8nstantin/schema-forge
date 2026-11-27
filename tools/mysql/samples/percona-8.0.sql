-- What Percona Server 8.0 adds to the sample (loaded after the MySQL samples of its version): a compression dictionary
-- and a column compressed with it.
CREATE COMPRESSION_DICTIONARY shop_words ('order customer product total placed');
CREATE TABLE shop.compressed_notes (
  id INT NOT NULL,
  body TEXT COLUMN_FORMAT COMPRESSED WITH COMPRESSION_DICTIONARY shop_words,
  PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
