# Queue

Tina4 Ruby includes a message queue system with Producer/Consumer pattern and pluggable backends: Lite (file-based, zero dependencies), RabbitMQ, and Kafka. Messages support topics, retry with max attempts, and dead letter queuing.

## Quick Start with Lite Backend

The Lite backend stores messages as JSON files in `.queue/`. No external services needed.

```ruby
require "tina4"

# Producer: publish messages
producer = Tina4::Producer.new
producer.publish("orders", { order_id: 123, total: 49.99 })
producer.publish("orders", { order_id: 124, total: 12.50 })

# Batch publish
producer.publish_batch("emails", [
  { to: "alice@example.com", subject: "Welcome" },
  { to: "bob@example.com", subject: "Reminder" }
])
```

## Consumer

```ruby
consumer = Tina4::Consumer.new(topic: "orders", max_retries: 3)

consumer.on_message do |message|
  puts "Processing order: #{message.payload}"
  puts "Message ID: #{message.id}"
  puts "Topic: #{message.topic}"
  puts "Attempt: #{message.attempts}"
  # Process the message...
end

# Start consuming (blocking -- runs in a loop)
consumer.start(poll_interval: 1)

# Or process a single message (non-blocking)
consumer.process_one
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

When a message handler raises an error:
1. The message is retried up to `max_retries` (default: 3)
2. After exhausting retries, the message moves to the dead letter queue

```ruby
consumer = Tina4::Consumer.new(topic: "risky", max_retries: 5)

consumer.on_message do |message|
  result = process_payment(message.payload)
  raise "Payment gateway timeout" unless result
end

consumer.start
# Failed messages after 5 attempts go to .queue/dead_letter/
```

## RabbitMQ Backend

```ruby
backend = Tina4::QueueBackends::RabbitmqBackend.new(
  url: "amqp://guest:guest@localhost:5672"
)

producer = Tina4::Producer.new(backend: backend)
producer.publish("notifications", { user_id: 1, type: "alert" })

consumer = Tina4::Consumer.new(topic: "notifications", backend: backend)
consumer.on_message do |message|
  send_notification(message.payload)
end
consumer.start
```

## Kafka Backend

```ruby
backend = Tina4::QueueBackends::KafkaBackend.new(
  brokers: ["localhost:9092"]
)

producer = Tina4::Producer.new(backend: backend)
producer.publish("events", { event: "user_signup", user_id: 42 })
```

## Shared Backend

Use the same backend instance across producers and consumers to share the queue.

```ruby
backend = Tina4::QueueBackends::LiteBackend.new(dir: ".queue")

producer = Tina4::Producer.new(backend: backend)
consumer = Tina4::Consumer.new(topic: "tasks", backend: backend)
```

## Lite Backend API

```ruby
backend = Tina4::QueueBackends::LiteBackend.new

backend.size("orders")   # => number of pending messages in topic
backend.topics           # => ["orders", "emails", ...]
```

## Background Consumer in Routes

```ruby
# Start consumer in a background thread
Thread.new do
  consumer = Tina4::Consumer.new(topic: "background_jobs")
  consumer.on_message do |msg|
    Tina4::Log.info("Processing background job: #{msg.id}")
    # do work...
  end
  consumer.start
end

# Publish from route handlers
Tina4.post "/api/jobs", auth: false do |request, response|
  producer = Tina4::Producer.new
  msg = producer.publish("background_jobs", request.body_parsed)
  response.json({ job_id: msg.id, status: "queued" }, status: 202)
end
```

## Stopping a Consumer

```ruby
consumer = Tina4::Consumer.new(topic: "orders")
consumer.on_message { |m| process(m) }

# In another thread or signal handler
consumer.stop
```
