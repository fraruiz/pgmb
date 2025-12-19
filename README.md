# pgmb

A lightweight message broker system built inside PostgreSQL. `pgmb` enables asynchronous message processing with HTTP-based worker dispatch, automatic retries, and dead letter queue support.

## Features

- **Worker Management**: Register HTTP endpoints as workers with configurable rate limits (RPS)
- **Queue System**: Create queues with pattern-based routing keys (supports wildcards)
- **Message Routing**: Automatic message routing based on routing keys matching binding patterns
- **HTTP Dispatch**: Automatic message delivery to worker endpoints via HTTP POST
- **Retry Logic**: Configurable retry attempts with exponential backoff support
- **Dead Letter Queue**: Failed messages after max retries are moved to DLQ
- **Scheduled Dispatch**: Uses `pg_cron` for automatic message dispatching
- **Delayed Messages**: Support for delayed message delivery

## Requirements

- PostgreSQL 12 or higher
- `pg_cron` extension
- `http` extension (for HTTP requests)

## Installation

### Using PGXN

```bash
pgxn install pgmb
```

### Manual Installation

1. Clone the repository:
```bash
git clone https://github.com/fraruiz/pgmb.git
cd pgmb
```

2. Build and install:
```bash
make
sudo make install
```

3. Enable the extension in your database:
```sql
CREATE EXTENSION pg_cron;
CREATE EXTENSION http;
CREATE EXTENSION pgmb;
```

## Quick Start

### 1. Register a Worker

```sql
SELECT pgmb.worker(
    'order_processor',                    -- worker name
    'http://localhost:8080/process',      -- endpoint URL
    100                                   -- requests per second limit
);
-- Returns: worker UUID
```

### 2. Create a Queue

```sql
SELECT pgmb.create(
    'order_queue',                        -- queue name
    'order.*',                            -- binding key pattern (supports *)
    '550e8400-e29b-41d4-a716-446655440000', -- worker UUID
    5                                     -- max retries
);
-- Returns: queue UUID
```

### 3. Send Messages

```sql
-- Simple message
SELECT pgmb.send(
    gen_random_uuid(),
    'order.created',
    '{"order_id": 123, "amount": 45.67}'::jsonb
);

-- With headers
SELECT pgmb.send(
    gen_random_uuid(),
    'order.created',
    '{"order_id": 123, "amount": 45.67}'::jsonb,
    '{"source": "web", "priority": "high"}'::jsonb
);

-- Delayed message (10 minutes)
SELECT pgmb.send(
    gen_random_uuid(),
    'order.created',
    '{"order_id": 123, "amount": 45.67}'::jsonb,
    '{"source": "web"}'::jsonb,
    now() + interval '10 minutes'
);

-- Delayed message (600 seconds)
SELECT pgmb.send(
    gen_random_uuid(),
    'order.created',
    '{"order_id": 123, "amount": 45.67}'::jsonb,
    '{"source": "web"}'::jsonb,
    600
);
```

## API Reference

### `pgmb.worker(name, endpoint, rps)`

Registers a new worker in the message broker.

**Parameters:**
- `name` (VARCHAR): The name of the worker
- `endpoint` (VARCHAR): The HTTP endpoint URL where messages will be sent
- `rps` (INT): Requests per second limit for rate limiting

**Returns:** UUID of the created worker

**Example:**
```sql
SELECT pgmb.worker('email_sender', 'http://api.example.com/send-email', 50);
```

### `pgmb.create(name, binding_key, max_retries, worker_id)`

Creates a new queue with a binding key pattern.

**Parameters:**
- `name` (VARCHAR): Unique name for the queue
- `binding_key` (VARCHAR): Pattern to match routing keys (supports `*` wildcard)
- `max_retries` (INT): Maximum number of retry attempts before moving to DLQ
- `worker_id` (UUID): The worker UUID that will process messages from this queue

**Returns:** UUID of the created queue

**Example:**
```sql
SELECT pgmb.create('order_queue', 'order.*', 5, '550e8400-e29b-41d4-a716-446655440000');
```

### `pgmb.send(id, routing_key, body)`

Sends a message to the broker.

**Parameters:**
- `id` (UUID): Unique identifier for the message
- `routing_key` (VARCHAR): Routing key for message routing
- `body` (JSONB): Message payload

**Returns:** VOID

**Example:**
```sql
SELECT pgmb.send(
    gen_random_uuid(),
    'order.created',
    '{"order_id": 123}'::jsonb
);
```

### `pgmb.send(id, routing_key, body, headers)`

Sends a message with custom headers.

**Parameters:**
- `id` (UUID): Unique identifier for the message
- `routing_key` (VARCHAR): Routing key for message routing
- `body` (JSONB): Message payload
- `headers` (JSONB): Optional message headers

**Returns:** VOID

### `pgmb.send(id, routing_key, body, headers, delay)`

Sends a delayed message. Delay can be a TIMESTAMP or INTEGER (seconds).

**Parameters:**
- `id` (UUID): Unique identifier for the message
- `routing_key` (VARCHAR): Routing key for message routing
- `body` (JSONB): Message payload
- `headers` (JSONB): Optional message headers
- `delay` (TIMESTAMPTZ or INT): When to enqueue the message

**Returns:** VOID

## How It Works

1. **Message Publishing**: When you call `pgmb.send()`, a message is inserted into `pgmb.messages` table.

2. **Automatic Routing**: A trigger (`enqueue_message_trigger`) automatically routes messages to matching queues based on routing key patterns.

3. **Queue Processing**: Each queue has its own table (`{queue_name}_queue`) that stores message references.

4. **Scheduled Dispatch**: `pg_cron` runs `pgmb.dispatch_messages()` every second for each queue, which:
   - Locks messages for processing (using `FOR UPDATE SKIP LOCKED`)
   - Sends HTTP POST requests to worker endpoints
   - Handles acknowledgments and retries
   - Moves failed messages to dead letter queues after max retries

5. **Dead Letter Queue**: Failed messages are moved to `{queue_name}_dead_letter_queue` after exceeding max retries.

## Database Schema

### Tables

- `pgmb.workers`: Stores worker registrations
- `pgmb.queues`: Stores queue definitions and bindings
- `pgmb.messages`: Stores all messages
- `pgmb.{queue_name}_queue`: Per-queue message references
- `pgmb.{queue_name}_dead_letter_queue`: Per-queue failed messages

## Monitoring

### Check Worker Status

```sql
SELECT * FROM pgmb.workers;
```

### Check Queue Status

```sql
SELECT * FROM pgmb.queues;
```

### Check Pending Messages

```sql
SELECT COUNT(*) FROM pgmb.order_queue WHERE acknoledge = false;
```

### Check Dead Letter Queue

```sql
SELECT * FROM pgmb.order_dead_letter_queue;
```

## Worker Endpoint Requirements

Your worker endpoints should:

- Accept HTTP POST requests
- Accept JSON body
- Return HTTP status codes:
  - `2xx`: Success (message will be acknowledged)
  - `4xx`/`5xx`: Failure (message will be retried)

**Example Worker Endpoint (Node.js):**

```javascript
app.post('/process', async (req, res) => {
  try {
    await processMessage(req.body);
    res.status(200).json({ success: true });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});
```

## License

PostgreSQL License

## Author

Francisco Ruiz - franciscoruizlezcano@gmail.com

## Repository

https://github.com/fraruiz/pgmb
