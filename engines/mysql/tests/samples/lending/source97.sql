-- What came after 8.4, loaded after source.sql into 9.7 and later only: vectors, and a foreign key written on its
-- column, which MySQL enforces from 9.0.
USE lending;

CREATE TABLE book_embeddings (
  isbn char(13) NOT NULL REFERENCES books (isbn) ON DELETE CASCADE,
  model varchar(40) NOT NULL,
  embedding vector(16) NOT NULL,
  PRIMARY KEY (isbn, model)
) ENGINE=InnoDB COMMENT='Vectors, for finding similar books';

INSERT INTO book_embeddings VALUES ('9780000000001', 'tiny', STRING_TO_VECTOR('[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16]'));
