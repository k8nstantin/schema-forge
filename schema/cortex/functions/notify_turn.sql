-- cortex.notify_turn: the bell every copy of a design listens for. When a turn commits, it gives the turn its number in
-- the design's commit order and rings schema_forge_turns with the design and that number, so every open canvas and
-- agent reads what changed.

CREATE FUNCTION cortex.notify_turn() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cortex AS $$
BEGIN
  IF NEW.state = 'committed' AND OLD.state = 'open' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.design::text, 0));
    NEW.seq := coalesce((SELECT max(seq) FROM cortex.turns WHERE design = NEW.design), 0) + 1;
    PERFORM pg_notify('schema_forge_turns', NEW.design::text || ':' || NEW.seq);
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER notify_turn BEFORE UPDATE OF state ON cortex.turns FOR EACH ROW EXECUTE FUNCTION cortex.notify_turn();

COMMENT ON FUNCTION cortex.notify_turn() IS 'numbers a turn in its design''s commit order as it commits, and rings schema_forge_turns with the design and the number';
