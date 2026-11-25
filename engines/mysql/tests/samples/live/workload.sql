-- The statements run on the live sample before it is read, inside the database, as an application would run them:
-- what the usage then shows. k_created_unused is never read; the join and the date filter use no index.
USE shop;
SELECT * FROM customers WHERE email = 'a@x.io';
SELECT * FROM customers WHERE country = 'US';
SELECT * FROM orders WHERE status = 'paid';
SELECT * FROM orders WHERE placed > '2020-01-01';
SELECT c.email, SUM(i.qty * p.price) FROM orders o JOIN customers c ON c.id = o.customer_id
  JOIN order_items i ON i.order_id = o.id JOIN products p ON p.id = i.product_id GROUP BY c.email ORDER BY 2 DESC;
SELECT * FROM big_orders;
CALL paid_orders();
UPDATE orders SET status = 'shipped' WHERE id = 2;
DELETE FROM order_items WHERE order_id = 4 AND product_id = 2;
