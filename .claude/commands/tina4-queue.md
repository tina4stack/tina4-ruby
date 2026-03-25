# Set Up Tina4 Background Queue

Set up a DB-backed job queue for background processing. Use this for any operation that takes more than ~1 second.

## Instructions

1. Create a route that pushes work to the queue
2. Create a worker that processes jobs
3. The queue table (`tina4_queue`) is auto-created

## Producer (in route)

```ruby
require "tina4/router"
require "tina4/queue"

Tina4::Router.post "/api/reports/generate" do |request, response|
  queue = Tina4::Queue.new(topic: "reports")
  queue.produce({
    "user_id" => request.body["user_id"],
    "type" => "monthly"
  })
  response.json({ "status" => "queued" })
end
```

## Consumer (separate worker)

Create `worker.rb`:
```ruby
require "tina4/queue"

queue = Tina4::Queue.new(topic: "reports") do |job|
  data = job.data
  # Do slow work here...
  report = generate_pdf(data["user_id"], data["type"])
  send_email(data["user_id"], report)
  job.complete
end

consumer = Tina4::Consumer.new(queue)
consumer.run_forever
```

Run: `ruby worker.rb`

## Queue Features

```ruby
require "tina4/queue"

queue = Tina4::Queue.new(topic: "emails")

# Push with priority (lower = higher priority)
queue.produce({ "to" => "user@test.com" })                     # default priority
queue.produce({ "to" => "vip@test.com" }, priority: 1)         # high priority

# Delayed jobs
queue.produce({ "action" => "reminder" }, delay_seconds: 3600) # run in 1 hour

# Pop a single job
job = queue.pop
if job
  process(job.data)
  job.complete        # mark done
  # or: job.fail("reason")
  # or: job.retry
end

# Queue management
queue.size                     # pending job count
queue.retry_failed             # retry all failed jobs
queue.dead_letters             # list permanently failed jobs
queue.purge                    # delete all completed jobs
```

## When to Use Queues

- Sending emails or SMS
- Generating PDFs/reports
- Calling slow external APIs
- Processing uploaded files (image resize, CSV import)
- Any operation the user should not wait for
