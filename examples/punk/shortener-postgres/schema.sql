-- Made by `punk check --schema` from the tables of the program. Until punk
-- has verified migrations (roadmap B2), a change to a table is a change you
-- also make to the database by hand.

CREATE TABLE IF NOT EXISTS links (
    id text PRIMARY KEY,
    url text NOT NULL,
    created bigint NOT NULL
);
ALTER TABLE links ENABLE ROW LEVEL SECURITY;
ALTER TABLE links FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS links_read ON links;
CREATE POLICY links_read ON links FOR SELECT USING (true);
DROP POLICY IF EXISTS links_insert ON links;
CREATE POLICY links_insert ON links FOR INSERT WITH CHECK (true);
DROP POLICY IF EXISTS links_update ON links;
DROP POLICY IF EXISTS links_delete ON links;
