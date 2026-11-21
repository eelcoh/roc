-- The shortener's table. The wiring applies this at startup (src/main.rs);
-- until punk has verified migrations (roadmap B2), a change here is a change
-- you make to the database by hand.
CREATE TABLE IF NOT EXISTS links (
    id text PRIMARY KEY,
    url text NOT NULL,
    created bigint NOT NULL
);
