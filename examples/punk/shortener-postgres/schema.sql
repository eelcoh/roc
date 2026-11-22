-- Made by `punk check --schema` from the tables of the program: one version
-- for each change of the tables. The wiring applies each version once, in
-- order, and refuses a version that changed after it was applied. Change
-- the tables in the program, not this file.

-- punk version 1
-- table links : id Str key, url Str, created Int
-- policy links read true
-- policy links insert true
-- policy links update -
-- policy links delete -
CREATE TABLE links (
    id text PRIMARY KEY,
    url text NOT NULL,
    created bigint NOT NULL
);
ALTER TABLE links ENABLE ROW LEVEL SECURITY;
ALTER TABLE links FORCE ROW LEVEL SECURITY;
CREATE POLICY links_read ON links FOR SELECT USING (true);
CREATE POLICY links_insert ON links FOR INSERT WITH CHECK (true);
