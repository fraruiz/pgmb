------------------------------------------------------------
-- Schema, tables, records, privileges, indexes, etc
------------------------------------------------------------
-- When installed as an extension, we don't need to create the `pgmq` schema
-- because it is automatically created by postgres due to being declared in
-- the extension control fi

CREATE SCHEMA IF NOT EXISTS pgmb;

CREATE TABLE IF NOT EXISTS pgmb.workers (
    "id"             uuid NOT NULL PRIMARY KEY,
    "name"           varchar NOT NULL,
    "rps"            int NOT NULL,
    "endpoint"       varchar NOT NULL,
    "created_at"     timestamptz NOT NULL DEFAULT now(),
    "last_heartbeat" timestamptz
);

CREATE TABLE IF NOT EXISTS pgmb.queues (
    "id"            uuid NOT NULL PRIMARY KEY,
    "name"          varchar UNIQUE NOT NULL,
    "binding_key"   varchar NOT NULL,
    "worker_id"     uuid NOT NULL,
    "max_retries"   int NOT NULL DEFAULT 5,
    "created_at"    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS pgmb.messages (
    "id"           uuid NOT NULL PRIMARY KEY,
    "routing_key"  varchar NOT NULL,
    "body"         jsonb NOT NULL,
    "headers"      jsonb NULL,
    "enqueued_at"  timestamptz NOT NULL DEFAULT now(),
    "occurred_at"  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE pgmb.queues ADD CONSTRAINT fk_worker FOREIGN KEY (worker_id) REFERENCES pgmb.workers(id) ON DELETE CASCADE;
CREATE INDEX idx_messages_id_brin ON pgmb.messages USING brin(enqueued_at);
CREATE INDEX idx_queues_binding_key ON pgmb.queues (binding_key);

/*
    Register a new worker in the message broker.

    @param name VARCHAR - The name of the worker.
    @param endpoint VARCHAR - The endpoint URL of the worker.
    @param rps INT - The requests per second limit for the worker.

    @example 
        SELECT pgmb.worker('order_processor', 'http://localhost:8080/process', 100);

    @returns UUID - The unique identifier of the created worker.
*/
CREATE FUNCTION pgmb.worker(name varchar, endpoint varchar, rps int)
RETURNS uuid AS $$
DECLARE
  identifier uuid;
  cron_name varchar;
  cron_exec varchar;
BEGIN
    SELECT gen_random_uuid() INTO identifier;

    INSERT INTO pgmb.workers (id, name, rps, endpoint) VALUES (identifier, name, rps, endpoint);

    RETURN identifier;
END;
$$ LANGUAGE plpgsql;

/*
    Create a new queue in the message broker.

    @param name VARCHAR - The name of the queue.
    @param binding_key VARCHAR - The binding key for the queue.
    @param worker_id UUID - The unique identifier of the worker associated with the queue.

    @example 
        SELECT pgmb.create('order_queue', 'order.*', '550e8400-e29b-41d4-a716-446655440000');

    @returns UUID - The unique identifier of the created queue.
*/
CREATE OR REPLACE FUNCTION pgmb.create(name varchar, binding_key varchar, max_retries int, worker_id uuid)
RETURNS uuid AS $$
DECLARE
  identifier uuid;
  cron_name text;
  cron_exec text;
BEGIN
    SELECT gen_random_uuid() INTO identifier;

    INSERT INTO pgmb.queues(id, name, binding_key, max_retries, worker_id, created_at) 
    VALUES (identifier, name, binding_key, max_retries, worker_id, now());

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS pgmb.%I_queue (
            "id"             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            "message_id"     uuid        NOT NULL,
            "acknoledge"     bool        NOT NULL DEFAULT false,
            "retries"        int4        NOT NULL DEFAULT 0,
            "locked"         bool        NOT NULL DEFAULT false,
            "enqueued_at"    timestamptz NOT NULL DEFAULT now(),
            "acknoledged_at" timestamptz
        );
    ', name);

    EXECUTE format('
        CREATE TABLE IF NOT EXISTS pgmb.%I_dead_letter_queue (
            "id"             BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            "message_id"     uuid        NOT NULL,
            "acknoledge"     bool        NOT NULL DEFAULT false,
            "retries"        int4        NOT NULL DEFAULT 0,
            "locked"         bool        NOT NULL DEFAULT false,
            "enqueued_at"    timestamptz NOT NULL DEFAULT now(),
            "acknoledged_at" timestamptz
        );
    ', name);

    -- Restricciones e Índices optimizados
    EXECUTE format('
        ALTER TABLE pgmb.%I_queue 
        ADD CONSTRAINT fk_msg_id 
        FOREIGN KEY (message_id) 
        REFERENCES pgmb.messages(id) 
        ON DELETE CASCADE;
    ', name);

    EXECUTE format('
        CREATE INDEX IF NOT EXISTS idx_%1$I_queue_dispatch 
        ON pgmb.%1$I_queue (locked, acknoledge, enqueued_at) 
        WHERE (locked = false AND acknoledge = false);
    ', name);

    EXECUTE format('
        CREATE INDEX IF NOT EXISTS idx_%1$I_dlq_msg_id ON pgmb.%1$I_dead_letter_queue (message_id);
        CREATE INDEX IF NOT EXISTS idx_%1$I_dlq_created ON pgmb.%1$I_dead_letter_queue (enqueued_at);
    ', name);

    cron_name := FORMAT('dispatch-%I-messages', name);
    cron_exec := FORMAT('SELECT pgmb.dispatch_messages(%L);', identifier);

    PERFORM cron.schedule(cron_name, '* * * * * *', cron_exec);

    RETURN identifier;
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.

    @example 
        SELECT pgmb.send(gen_random_uuid(), 'order.created', '{"order_id": 123, "amount": 45.67}');

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.messages (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, null, now(), now());
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.
    @param headers JSONB - Optional headers for the message.

    @example 
        SELECT pgmb.send(
            gen_random_uuid(), 
            'order.created', 
            '{"order_id": 123, "amount": 45.67}', 
            '{"source": "web", "priority": "high"}'
        );

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb, headers jsonb)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.send (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, headers, now(), now());
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.
    @param headers JSONB - Optional headers for the message.
    @param delay TIMESTAMP WITH TIME ZONE - The time to enqueue the message.

    @example 
        SELECT pgmb.send(
            gen_random_uuid(), 
            'order.created', 
            '{"order_id": 123, "amount": 45.67}', 
            '{"source": "web", "priority": "high"}',
            now() + interval '10 minutes'
        );

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb, headers jsonb, delay TIMESTAMP WITH TIME ZONE)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.messages (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, headers, delay, now());
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.
    @param headers JSONB - Optional headers for the message.
    @param delay INTEGER - The delay in seconds before enqueuing the message.

    @example 
        SELECT pgmb.send(
            gen_random_uuid(), 
            'order.created', 
            '{"order_id": 123, "amount": 45.67}', 
            '{"source": "web", "priority": "high"}',
            600
        );

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb, headers jsonb, delay integer)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.messages (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, headers, clock_timestamp() + make_interval(secs => delay), now());
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.
    @param delay TIMESTAMP WITH TIME ZONE - The time to enqueue the message.

    @example 
        SELECT pgmb.send(
            gen_random_uuid(), 
            'order.created', 
            '{"order_id": 123, "amount": 45.67}', 
            now() + interval '10 minutes'
        );

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb, delay TIMESTAMP WITH TIME ZONE)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.messages (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, null, delay, now());
END;
$$ LANGUAGE plpgsql;


/*
    Send message to the message broker.

    @param id UUID - The unique identifier for the message.
    @param routing_key VARCHAR - The routing key for the message.
    @param body JSONB - The body of the message.
    @param delay INTEGER - The delay in seconds before enqueuing the message.

    @example 
        SELECT pgmb.send(
            gen_random_uuid(), 
            'order.created', 
            '{"order_id": 123, "amount": 45.67}', 
            600
        );

    @returns VOID
*/
CREATE FUNCTION pgmb.send(id uuid, routing_key varchar, body jsonb, delay integer)
RETURNS VOID AS $$
DECLARE
BEGIN
    INSERT INTO pgmb.messages (id, routing_key, body, headers, enqueued_at, occurred_at) VALUES (id, routing_key, body, null, clock_timestamp() + make_interval(secs => delay), now());
END;
$$ LANGUAGE plpgsql;

/*
    Trigger function to enqueue messages into appropriate queues based on routing keys.
*/
CREATE OR REPLACE FUNCTION pgmb.enqueue_message()
RETURNS TRIGGER AS $$
DECLARE
    target_queue RECORD;
BEGIN
    FOR target_queue IN SELECT name FROM pgmb.queues WHERE NEW.routing_key LIKE replace(binding_key, '*', '%')
    LOOP
        EXECUTE format('
            INSERT INTO pgmb.%I_queue (message_id, enqueued_at) 
            VALUES ($1, $2)
        ', target_queue.name)
        USING NEW.id, NEW.enqueued_at;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER enqueue_message_trigger
AFTER INSERT ON pgmb.messages
FOR EACH ROW
EXECUTE FUNCTION pgmb.enqueue_message();

CREATE OR REPLACE FUNCTION pgmb.dispatch_messages(queue_id uuid)
RETURNS void AS $$
DECLARE
    queue_record RECORD;
    worker_record RECORD;
    message_record RECORD;
    response_status INT;
BEGIN
    SELECT * FROM pgmb.queues WHERE id = queue_id INTO STRICT queue_record;    
    SELECT * FROM pgmb.workers WHERE id = queue_record.worker_id INTO STRICT worker_record;

    -- 1. Bloqueamos mensajes y obtenemos sus datos y reintentos en un solo paso
    FOR message_record IN EXECUTE FORMAT('
        WITH target AS (
            SELECT id FROM pgmb.%I_queue 
            WHERE acknoledge = false AND locked = false 
            ORDER BY enqueued_at ASC 
            LIMIT $1 
            FOR UPDATE SKIP LOCKED
        )
        UPDATE pgmb.%I_queue q
        SET locked = true 
        FROM target
        WHERE q.id = target.id
        RETURNING q.message_id, q.retries, 
                  (SELECT body FROM pgmb.messages WHERE id = q.message_id) as body
    ', queue_record.name, queue_record.name) USING worker_record.rps 
    LOOP
        
        -- 2. Intentar envío vía HTTP
        BEGIN
            SELECT status INTO response_status 
            FROM http_post(worker_record.endpoint, message_record.body::text, 'application/json');
        EXCEPTION WHEN OTHERS THEN
            response_status := 500; -- Error de red o timeout
        END;

        -- 3. Lógica de éxito o reintento/DLQ
        IF response_status >= 200 AND response_status < 300 THEN
            EXECUTE FORMAT('UPDATE pgmb.%I_queue SET acknoledge = true, locked = false, acknoledged_at = now() WHERE message_id = $1', queue_record.name) 
            USING message_record.message_id;
        ELSE
            IF message_record.retries >= queue_record.max_retries THEN
                -- MOVER A DEAD LETTER QUEUE
                EXECUTE FORMAT('
                    INSERT INTO pgmb.%I_dead_letter_queue (message_id, retries, enqueued_at) 
                    VALUES ($1, $2, now());
                    DELETE FROM pgmb.%I_queue WHERE message_id = $1;
                ', queue_record.name, queue_record.name) 
                USING message_record.message_id, message_record.retries;
            ELSE
                -- INCREMENTAR REINTENTOS
                EXECUTE FORMAT('UPDATE pgmb.%I_queue SET retries = retries + 1, locked = false WHERE message_id = $1', queue_record.name) 
                USING message_record.message_id;
            END IF;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;