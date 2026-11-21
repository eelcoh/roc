-- Made by `punk check --schema` from the tables of the program. Until punk
-- has verified migrations (roadmap B2), a change to a table is a change you
-- also make to the database by hand.

CREATE TABLE IF NOT EXISTS notes (
    id text PRIMARY KEY,
    owner text NOT NULL,
    text text NOT NULL,
    public boolean NOT NULL
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE notes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notes_read ON notes;
CREATE POLICY notes_read ON notes FOR SELECT USING (public OR owner = NULLIF(current_setting('punk.user_id', true), ''));
DROP POLICY IF EXISTS notes_insert ON notes;
CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
DROP POLICY IF EXISTS notes_update ON notes;
CREATE POLICY notes_update ON notes FOR UPDATE USING (owner = NULLIF(current_setting('punk.user_id', true), '')) WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
DROP POLICY IF EXISTS notes_delete ON notes;
CREATE POLICY notes_delete ON notes FOR DELETE USING (owner = NULLIF(current_setting('punk.user_id', true), ''));
