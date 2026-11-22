-- Made by `punk check --schema` from the tables of the program: one version
-- for each change of the tables. The wiring applies each version once, in
-- order, and refuses a version that changed after it was applied. Change
-- the tables in the program, not this file.

-- punk version 1
-- table notes : id Str key, owner Str, text Str, public Bool
-- policy notes read public OR owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes insert owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes update owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes delete owner = NULLIF(current_setting('punk.user_id', true), '')
CREATE TABLE notes (
    id text PRIMARY KEY,
    owner text NOT NULL,
    text text NOT NULL,
    public boolean NOT NULL
);
ALTER TABLE notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE notes FORCE ROW LEVEL SECURITY;
CREATE POLICY notes_read ON notes FOR SELECT USING (public OR owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_update ON notes FOR UPDATE USING (owner = NULLIF(current_setting('punk.user_id', true), '')) WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_delete ON notes FOR DELETE USING (owner = NULLIF(current_setting('punk.user_id', true), ''));

-- punk version 2
-- table notes : id Str key, owner Str, body Str, public Bool, pinned Bool
-- policy notes read public OR owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes insert owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes update owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes delete owner = NULLIF(current_setting('punk.user_id', true), '') AND NOT pinned
DROP POLICY IF EXISTS notes_read ON notes;
DROP POLICY IF EXISTS notes_insert ON notes;
DROP POLICY IF EXISTS notes_update ON notes;
DROP POLICY IF EXISTS notes_delete ON notes;
ALTER TABLE notes NO FORCE ROW LEVEL SECURITY;
ALTER TABLE notes ADD COLUMN pinned boolean;
UPDATE notes SET pinned = FALSE;
ALTER TABLE notes RENAME COLUMN text TO body;
ALTER TABLE notes ALTER COLUMN pinned SET NOT NULL;
ALTER TABLE notes FORCE ROW LEVEL SECURITY;
CREATE POLICY notes_read ON notes FOR SELECT USING (public OR owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_insert ON notes FOR INSERT WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_update ON notes FOR UPDATE USING (owner = NULLIF(current_setting('punk.user_id', true), '')) WITH CHECK (owner = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY notes_delete ON notes FOR DELETE USING (owner = NULLIF(current_setting('punk.user_id', true), '') AND NOT pinned);

-- punk version 3
-- table notes : id Str key, owner Str, body Str, public Bool, pinned Bool
-- policy notes read public OR owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes insert owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes update owner = NULLIF(current_setting('punk.user_id', true), '')
-- policy notes delete owner = NULLIF(current_setting('punk.user_id', true), '') AND NOT pinned
-- table people : id Str key, name Str
-- policy people read true
-- policy people insert id = NULLIF(current_setting('punk.user_id', true), '')
-- policy people update id = NULLIF(current_setting('punk.user_id', true), '')
-- policy people delete -
CREATE TABLE people (
    id text PRIMARY KEY,
    name text NOT NULL
);
ALTER TABLE people ENABLE ROW LEVEL SECURITY;
ALTER TABLE people FORCE ROW LEVEL SECURITY;
CREATE POLICY people_read ON people FOR SELECT USING (true);
CREATE POLICY people_insert ON people FOR INSERT WITH CHECK (id = NULLIF(current_setting('punk.user_id', true), ''));
CREATE POLICY people_update ON people FOR UPDATE USING (id = NULLIF(current_setting('punk.user_id', true), '')) WITH CHECK (id = NULLIF(current_setting('punk.user_id', true), ''));
