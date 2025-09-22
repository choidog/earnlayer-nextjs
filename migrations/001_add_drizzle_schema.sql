-- Migration 001: Add Drizzle Schema
-- Purpose: Create Drizzle schema for migration tracking

CREATE SCHEMA IF NOT EXISTS drizzle;

CREATE TABLE IF NOT EXISTS drizzle.__drizzle_migrations (
    id serial PRIMARY KEY,
    hash text NOT NULL,
    created_at bigint
);

COMMENT ON SCHEMA drizzle IS 'Schema for Drizzle ORM migration tracking';
COMMENT ON TABLE drizzle.__drizzle_migrations IS 'Tracks applied database migrations';