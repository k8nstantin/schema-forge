-- MySQL sample: names a reader must quote, a reserved word, a view whose table is gone, a routine named like a keyword.
CREATE DATABASE `Quoted Names`;
CREATE TABLE `Quoted Names`.`Order` (`Select` INT PRIMARY KEY, `two words` VARCHAR(10), `back``tick` INT, `ünïcode` TEXT);
CREATE TABLE `Quoted Names`.`my.table` (id INT PRIMARY KEY, `it's` VARCHAR(5) COMMENT 'a comment with ''quotes'' and a ; semicolon');
CREATE TABLE `Quoted Names`.`it's` (id INT PRIMARY KEY);
CREATE TABLE `Quoted Names`.`MixedCase` (id INT PRIMARY KEY);
CREATE TABLE `Quoted Names`.`mixedcase` (id INT PRIMARY KEY);
CREATE TABLE `Quoted Names`.`gone_soon` (id INT PRIMARY KEY);
CREATE VIEW `Quoted Names`.`v broken` AS SELECT id FROM `Quoted Names`.`gone_soon`;
DROP TABLE `Quoted Names`.`gone_soon`;
CREATE PROCEDURE `Quoted Names`.`select`() SELECT 1;
