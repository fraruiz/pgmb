# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - Initial Release

### Added

#### Core Features
- **Worker Management System**
  - `pgmb.worker()` function to register HTTP worker endpoints
  - Worker rate limiting support (RPS - Requests Per Second)
  - Worker heartbeat tracking via `last_heartbeat` field
  - Worker metadata storage (name, endpoint, RPS limits)

- **Queue System**
  - `pgmb.create()` function to create queues with binding keys
  - Pattern-based routing key matching (supports `*` wildcard)
  - Per-queue retry configuration (`max_retries`)
  - Automatic queue table creation (`{queue_name}_queue`)
  - Automatic dead letter queue creation (`{queue_name}_dead_letter_queue`)

- **Message Publishing**
  - `pgmb.send()` function with multiple overloads:
    - Basic message sending (id, routing_key, body)
    - Message with headers support
    - Delayed message delivery (TIMESTAMP or INTEGER seconds)
  - JSONB message body support
  - Optional message headers (JSONB)
  - Message metadata tracking (`enqueued_at`, `occurred_at`)

- **Automatic Message Routing**
  - Trigger-based automatic message enqueueing
  - Pattern matching between routing keys and binding keys
  - Support for wildcard patterns (`*` matches any sequence)

- **Message Dispatch System**
  - `pgmb.dispatch_messages()` function for HTTP-based message delivery
  - Integration with `pg_cron` for scheduled dispatching (every second)
  - Automatic cron job creation per queue
  - HTTP POST requests to worker endpoints
  - Rate limiting enforcement based on worker RPS settings

- **Retry and Error Handling**
  - Configurable retry attempts per queue
  - Automatic retry on HTTP errors (4xx/5xx status codes)
  - Retry counter tracking per message
  - Dead letter queue for failed messages after max retries

- **Concurrency Control**
  - Row-level locking with `FOR UPDATE SKIP LOCKED` for safe concurrent processing
  - Message locking mechanism to prevent duplicate processing
  - Acknowledgment system for processed messages

#### Database Schema
- `pgmb.workers` table for worker registration
- `pgmb.queues` table for queue definitions
- `pgmb.messages` table for message storage
- Dynamic per-queue tables for message references
- Dynamic per-queue dead letter queue tables

#### Indexes and Performance
- BRIN index on `messages.enqueued_at` for efficient time-based queries
- Index on `queues.binding_key` for fast routing key lookups
- Partial indexes on queue tables for efficient dispatch queries (`locked = false AND acknoledge = false`)
- Foreign key constraints for referential integrity

#### Dependencies
- Requires `pg_cron` extension for scheduled message dispatch
- Requires `http` extension for HTTP requests to worker endpoints

### Technical Details

- **PostgreSQL Version Support**: PostgreSQL 12+
- **Schema**: `pgmb` (automatically created)
- **Extension Version**: 1.0.0
- **License**: PostgreSQL License

### Documentation

- Comprehensive README with installation instructions
- API reference documentation
- Usage examples for all functions
- Worker endpoint requirements documentation

---

[1.0.0]: https://github.com/fraruiz/pgmb/releases/tag/v1.0.0

