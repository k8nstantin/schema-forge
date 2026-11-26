-- notify_turns: the bell a design's copies listen for. Owner: cortex.
-- When a turn is given its number in its design's commit order (cortex.turns.seq), the database sends, after commit,
-- a notification on the channel schema_forge_turns whose payload is the design and the number: "<design> <seq>". It is
-- only a bell, never the change: a copy that hears it reads the log's turns after the number it holds, and one that
-- was away asks the log the same on connecting (decision work-from-memory). Every writer rings it, the app's account
-- and a coding agent's alike, since the database does.

CREATE FUNCTION cortex.notify_turns() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('schema_forge_turns', NEW.design::text || ' ' || NEW.seq::text);
  RETURN NULL;
END $$;

CREATE TRIGGER notify_turns AFTER INSERT OR UPDATE OF seq ON cortex.turns
  FOR EACH ROW WHEN (NEW.seq IS NOT NULL) EXECUTE FUNCTION cortex.notify_turns();
