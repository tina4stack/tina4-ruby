# Queue

Tina4 Ruby includes a message queue system with pluggable backends: Lite (file-based, zero dependencies), RabbitMQ, Kafka, and MongoDB. Messages support topics, retry with max attempts, and dead letter queuing.

## Quick Start with Lite Backend

The Lite backend stores messages as JSON files in `.queue/`. No external services needed.

```ruby
require "tina4"

# Create a queue for a topic
queue = Tina4::Queue.new(topic: "orders")

# Produce messages
queue.produce("orders", { order_id: 123, total: 49.99 })
queue.produce("orders", { order_id: 124, total: 12.50 })

# Or use push for the default topic
queue.push({ order_id: 125, total: 30.00 })
```

## Consuming Messages

```ruby
queue = Tina4::Queue.new(topic: "orders", max_retries: 3)

# Block-based consumption (processes all pending messages)
queue.consume("orders") do |message|
  puts "Processing order: #{message.payload}"
  puts "Message ID: #{message.id}"
  puts "Topic: #{message.topic}"
  puts "Attempt: #{message.attempts}"
  # Process the message...
end

# Consume a specific message by ID
queue.consume("orders", id: "abc-123") do |message|
  puts "Processing specific order: #{message.payload}"
end

# Or as an enumerator
queue.consume("orders").each { |job| process(job) }

# Or pop one at a time
msg = queue.pop
process(msg) if msg
```

## QueueMessage

```ruby
message.id          # => UUID string
message.topic       # => "orders"
message.payload     # => { order_id: 123, total: 49.99 }
message.created_at  # => Time
message.attempts    # => Integer
message.status      # => :pending, :processing, :completed, :failed
message.to_hash     # => full hash representation
message.to_json     # => JSON string
```

## Retry and Dead Letter

When a message fails processing:
1. Use `queue.retry_failed` to re-queue messages under `max_retries`
2. Messages that exceed retries go to the dead letter queue

```ruby
queue = Tina4::Queue.new(topic: "risky", max_retries: 5)

# Check dead letter queue
dead = queue.dead_letters

# Retry failed messages
queue.retry_failed

# Purge completed messages
queue.purge("completed")
```

## RabbitMQ Backend

```ruby
queue = Tina4::Queue.new(topic: "notifications", backend: :rabbitmq)

queue.produce("notifications", { user_id: 1, type: "alert" })

queue.consume("notifications") do |message|
  send_notification(message.payload)
end
```

Configure via environment variables:
- `TINA4_QUEUE_BACKEND=rabbitmq`
- `TINA4_QUEUE_URL=amqp://guest:guest@localhost:5672`

## Kafka Backend

```ruby
queue = Tina4::Queue.new(topic: "events", backend: :kafka)
queue.produce("events", { event: "user_signup", user_id: 42 })
```

Configure via environment variables:
- `TINA4_QUEUE_BACKEND=kafka`
- `TINA4_KAFKA_BROKERS=localhost:9092`

## Explicit Backend Instance

Pass a backend instance directly for full control:

```ruby
backend = Tina4::QueueBackends::LiteBackend.new(dir: ".queue")
queue = Tina4::Queue.new(topic: "tasks", backend: backend)

queue.produce("tasks", { action: "send_email" })
queue.consume("tasks") do |msg|
  process(msg)
end
```

## Lite Backend API

```ruby
backend = Tina4::QueueBackends::LiteBackend.new

backend.size("orders")   # => number of pending messages in topic
backend.topics           # => ["orders", "emails", ...]
```

## Background Queue in Routes

```ruby
# Start consumer in a background thread
Thread.new do
  queue = Tina4::Queue.new(topic: "background_jobs")
  queue.consume("background_jobs") do |msg|
    Tina4::Log.info("Processing background job: #{msg.id}")
    # do work...
  end
end

# Publish from route handlers
Tina4.post "/api/jobs", auth: false do |request, response|
  queue = Tina4::Queue.new(topic: "background_jobs")
  msg = queue.produce("background_jobs", request.body_parsed)
  response.json({ job_id: msg.id, status: "queued" }, status: 202)
end
```
