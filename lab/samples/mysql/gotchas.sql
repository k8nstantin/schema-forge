-- MySQL gotchas: names a reader must quote, a reserved word, a view whose table is gone, a routine named like a keyword.
CREATE DATABASE `Gotcha Zone`;
CREATE TABLE `Gotcha Zone`.`Order` (`Select` INT PRIMARY KEY, `two words` VARCHAR(10), `back``tick` INT, `ünïcode` TEXT);
CREATE TABLE `Gotcha Zone`.`my.table` (id INT PRIMARY KEY, `it's` VARCHAR(5) COMMENT 'a comment with ''quotes'' and a ; semicolon');
CREATE TABLE `Gotcha Zone`.`it's` (id INT PRIMARY KEY);
CREATE TABLE `Gotcha Zone`.`MixedCase` (id INT PRIMARY KEY);
CREATE TABLE `Gotcha Zone`.`mixedcase` (id INT PRIMARY KEY);
CREATE TABLE `Gotcha Zone`.`gone_soon` (id INT PRIMARY KEY);
CREATE VIEW `Gotcha Zone`.`v broken` AS SELECT id FROM `Gotcha Zone`.`gone_soon`;
DROP TABLE `Gotcha Zone`.`gone_soon`;
CREATE PROCEDURE `Gotcha Zone`.`select`() SELECT 1;
