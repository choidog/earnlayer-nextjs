-- Sequences for schema public
CREATE SEQUENCE public.api_logs_id_seq AS int4 INCREMENT BY 1 MINVALUE 1 MAXVALUE 2147483647 START WITH 1 CACHE 1 NO CYCLE;
ALTER SEQUENCE public.api_logs_id_seq OWNED BY public.api_logs.id;
