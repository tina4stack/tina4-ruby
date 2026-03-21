# Gallery: Queue — produce and consume background jobs.

Tina4::Router.post("/api/gallery/queue/produce") do |request, response|
  body = request.body || {}
  task = body["task"] || "default-task"
  data = body["data"] || {}

  begin
    db = Tina4::Database.new("sqlite://data/gallery_queue.db")
    queue = Tina4::Queue.new(db, topic: "gallery-tasks")
    producer = Tina4::Producer.new(queue)
    producer.produce({ task: task, data: data })
    response.json({ queued: true, task: task }, 201)
  rescue => e
    response.json({ queued: true, task: task, note: "Queue demo (#{e.message})" }, 201)
  end
end

Tina4::Router.get("/api/gallery/queue/status") do |request, response|
  begin
    db = Tina4::Database.new("sqlite://data/gallery_queue.db")
    queue = Tina4::Queue.new(db, topic: "gallery-tasks")
    response.json({ topic: "gallery-tasks", size: queue.size })
  rescue => e
    response.json({ topic: "gallery-tasks", size: 0, note: "Queue demo (#{e.message})" })
  end
end
