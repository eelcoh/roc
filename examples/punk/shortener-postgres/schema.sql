-- Made by `punk check --schema` from the tables of the program. Until punk
-- has verified migrations (roadmap B2), a change to a table is a change you
-- also make to the database by hand.

CREATE TABLE IF NOT EXISTS links (
    id text PRIMARY KEY,
    url text NOT NULL,
    created bigint NOT NULL
);
