-- workspace_parameters: the values version 1 ships. Owner: cortex.
-- Inserted only where the key is missing: a value a person changed is never overwritten by a later version's seed.
INSERT INTO cortex.workspace_parameters (id, value, about) VALUES
  ('product.name', '"SchemaForge"', 'the product''s name, as every screen, message, page and written file says it'),
  ('product.repository', '"https://github.com/k8nstantin/schema-forge"', 'where the product''s source, issues and discussions are'),
  ('product.site', '"https://k8nstantin.github.io/schema-forge/"', 'the product''s website, where its pages and the brief for coding agents are'),
  ('product.branch', '"main"', 'the branch the released source and the spec are read from')
ON CONFLICT (id) DO NOTHING;
