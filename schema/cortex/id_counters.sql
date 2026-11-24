-- cortex.id_counters: the last number given to a kind of part under its parent, so a number is given once and never reused. Owner: cortex.
-- A part the model gives no id is named <parent>.<word><n> (o_orders.index3); its n is this row's last plus one,
-- written in the same transaction as the part. A part deleted keeps its number used: the next is still one more.
CREATE TABLE cortex.id_counters (
  id    TEXT    NOT NULL PRIMARY KEY CHECK (length(id) >= 3 AND id = rtrim(id, '0123456789')),  -- the id of a part without its number: <parent>.<word> (o_orders.key), <parent>. when the word is empty (o_orders.key1.), <word> when there is no parent (statement)
  last  INTEGER NOT NULL CHECK (last >= 1)                                                      -- the last number given: the next part is <id><last + 1>
);

COMMENT ON TABLE cortex.id_counters IS 'the last number given to a kind of part under its parent, so a number is given once and never reused. A part the model gives no id is named <parent>.<word><n> (o_orders.index3); its n is this row''s last plus one, written in the same transaction as the part. A part deleted keeps its number used: the next is still one more.';
COMMENT ON COLUMN cortex.id_counters.id IS 'the id of a part without its number: <parent>.<word> (o_orders.key), <parent>. when the word is empty (o_orders.key1.), <word> when there is no parent (statement)';
COMMENT ON COLUMN cortex.id_counters.last IS 'the last number given: the next part is <id><last + 1>';
