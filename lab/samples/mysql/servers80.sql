-- What the server holds from 8.0 on: a spatial reference system of its own, a column that names it, and a tablespace
-- that grows by a set size (8.0.23 and later).
CREATE SPATIAL REFERENCE SYSTEM 1000001 NAME 'lab grid' ORGANIZATION 'lab' IDENTIFIED BY 1000001
  DEFINITION 'GEOGCS["lab grid",DATUM["World Geodetic System 1984",SPHEROID["WGS 84",6378137,298.257223563]],PRIMEM["Greenwich",0],UNIT["degree",0.017453292519943278],AXIS["Lat",NORTH],AXIS["Lon",EAST]]'
  DESCRIPTION 'the lab''s own grid';
CREATE TABLE features.on_grid (id INT PRIMARY KEY, spot GEOMETRY NOT NULL SRID 1000001);
CREATE TABLESPACE ts_grow ADD DATAFILE 'ts_grow.ibd' AUTOEXTEND_SIZE = 4M ENGINE = InnoDB;
