# Gallery: Queue — interactive queue demo with visual web UI.
#
# Uses a SQLite database directly for the demo queue table,
# matching the Python gallery demo's database-backed approach.

require "json"

def _gallery_queue_db
  @_gallery_queue_db ||= begin
    db = Tina4::Database.new("sqlite://data/gallery_queue.db")
    unless db.table_exists?("tina4_queue")
      db.execute("CREATE TABLE tina4_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        topic TEXT NOT NULL,
        data TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        priority INTEGER NOT NULL DEFAULT 0,
        attempts INTEGER NOT NULL DEFAULT 0,
        error TEXT,
        available_at TEXT NOT NULL,
        created_at TEXT NOT NULL,
        completed_at TEXT,
        reserved_at TEXT
      )")
    end
    db
  end
end

def _gallery_queue_now
  Time.now.utc.iso8601
end

GALLERY_QUEUE_MAX_RETRIES = 3

GALLERY_QUEUE_HTML = <<~'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Queue Gallery — Tina4 Ruby</title>
    <link rel="stylesheet" href="/css/tina4.min.css">
</head>
<body>
<div class="container mt-4 mb-4">
    <h1>Queue Gallery</h1>
    <p class="text-muted">Interactive demo of Tina4's database-backed job queue. Produce messages, consume them, simulate failures, and inspect dead letters.</p>

    <div class="row mt-3">
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">Produce a Message</div>
                <div class="card-body">
                    <div class="d-flex gap-2">
                        <input type="text" id="msgInput" class="form-control" placeholder="Enter a task message, e.g. send-email">
                        <button class="btn btn-primary" onclick="produce()">Produce</button>
                    </div>
                </div>
            </div>
        </div>
        <div class="col-md-6">
            <div class="card">
                <div class="card-header">Actions</div>
                <div class="card-body d-flex gap-2 flex-wrap">
                    <button class="btn btn-success" onclick="consume()">Consume Next</button>
                    <button class="btn btn-danger" onclick="failNext()">Fail Next</button>
                    <button class="btn btn-warning" onclick="retryFailed()">Retry Failed</button>
                    <button class="btn btn-secondary" onclick="refresh()">Refresh</button>
                </div>
            </div>
        </div>
    </div>

    <div id="alertArea" class="mt-3"></div>

    <div class="card mt-3">
        <div class="card-header d-flex justify-content-between align-items-center">
            <span>Queue Messages</span>
            <small class="text-muted" id="lastRefresh"></small>
        </div>
        <div class="card-body p-0">
            <table class="table table-striped mb-0">
                <thead>
                    <tr>
                        <th>ID</th>
                        <th>Data</th>
                        <th>Status</th>
                        <th>Attempts</th>
                        <th>Error</th>
                        <th>Created</th>
                    </tr>
                </thead>
                <tbody id="queueBody">
                    <tr><td colspan="6" class="text-center text-muted">Loading...</td></tr>
                </tbody>
            </table>
        </div>
    </div>
</div>

<script>
function statusBadge(status) {
    var colors = {pending:"primary", reserved:"warning", completed:"success", failed:"danger", dead:"secondary"};
    var color = colors[status] || "secondary";
    return '<span class="badge bg-' + color + '">' + status + '</span>';
}

function showAlert(msg, type) {
    var area = document.getElementById("alertArea");
    area.innerHTML = '<div class="alert alert-' + type + ' alert-dismissible">' + msg +
        '<button type="button" class="btn-close" onclick="this.parentElement.remove()"></button></div>';
    setTimeout(function(){ area.innerHTML = ""; }, 3000);
}

function truncate(s, n) {
    if (!s) return "";
    return s.length > n ? s.substring(0, n) + "..." : s;
}

async function refresh() {
    try {
        var r = await fetch("/api/gallery/queue/status");
        var data = await r.json();
        var tbody = document.getElementById("queueBody");
        if (!data.messages || data.messages.length === 0) {
            tbody.innerHTML = '<tr><td colspan="6" class="text-center text-muted">No messages in queue. Produce one above.</td></tr>';
        } else {
            var html = "";
            for (var i = 0; i < data.messages.length; i++) {
                var m = data.messages[i];
                html += "<tr><td>" + m.id + "</td><td><code>" + truncate(m.data, 60) + "</code></td><td>" +
                    statusBadge(m.status) + "</td><td>" + m.attempts + "</td><td>" +
                    truncate(m.error || "", 40) + "</td><td><small>" + (m.created_at || "") + "</small></td></tr>";
            }
            tbody.innerHTML = html;
        }
        document.getElementById("lastRefresh").textContent = "Updated " + new Date().toLocaleTimeString();
    } catch (e) {
        console.error(e);
    }
}

async function produce() {
    var input = document.getElementById("msgInput");
    var task = input.value.trim() || "demo-task";
    var r = await fetch("/api/gallery/queue/produce", {
        method: "POST", headers: {"Content-Type":"application/json"},
        body: JSON.stringify({task: task, data: {message: task}})
    });
    var d = await r.json();
    showAlert("Produced message: " + task, "success");
    input.value = "";
    refresh();
}

async function consume() {
    var r = await fetch("/api/gallery/queue/consume", {method:"POST"});
    var d = await r.json();
    if (d.consumed) {
        showAlert("Consumed job #" + d.job_id + " successfully", "success");
    } else {
        showAlert(d.message || "Nothing to consume", "info");
    }
    refresh();
}

async function failNext() {
    var r = await fetch("/api/gallery/queue/fail", {method:"POST"});
    var d = await r.json();
    if (d.failed) {
        showAlert("Deliberately failed job #" + d.job_id, "danger");
    } else {
        showAlert(d.message || "Nothing to fail", "info");
    }
    refresh();
}

async function retryFailed() {
    var r = await fetch("/api/gallery/queue/retry", {method:"POST"});
    var d = await r.json();
    showAlert("Retried " + (d.retried || 0) + " failed message(s)", "warning");
    refresh();
}

refresh();
setInterval(refresh, 2000);
</script>
</body>
</html>
HTML

# ── Render the interactive HTML page ──────────────────────────

Tina4::Router.get("/gallery/queue") do |request, response|
  response.html(GALLERY_QUEUE_HTML)
end

# ── Produce — add a message to the queue ──────────────────────

Tina4::Router.post("/api/gallery/queue/produce") do |request, response|
  body = request.body || {}
  task = body["task"] || "default-task"
  data = body["data"] || {}

  db = _gallery_queue_db
  now = _gallery_queue_now
  payload = JSON.generate({ task: task, data: data })

  db.execute(
    "INSERT INTO tina4_queue (topic, data, status, priority, attempts, available_at, created_at) VALUES (?, ?, 'pending', 0, 0, ?, ?)",
    ["gallery-tasks", payload, now, now]
  )

  row = db.fetch_one("SELECT last_insert_rowid() as last_id")
  job_id = row ? row["last_id"] : 0

  response.json({ queued: true, task: task, job_id: job_id }, 201)
end

# ── Status — list all messages with statuses ──────────────────

Tina4::Router.get("/api/gallery/queue/status") do |request, response|
  db = _gallery_queue_db

  result = db.fetch(
    "SELECT * FROM tina4_queue WHERE topic = ? ORDER BY id DESC",
    ["gallery-tasks"],
    limit: 100
  )

  messages = []
  counts = { pending: 0, reserved: 0, completed: 0, failed: 0 }

  (result.respond_to?(:records) ? result.records : (result || [])).each do |row|
    status = row["status"] || "pending"
    attempts = (row["attempts"] || 0).to_i

    display_status = status
    if status == "failed" && attempts >= GALLERY_QUEUE_MAX_RETRIES
      display_status = "dead"
    end

    counts[status.to_sym] = (counts[status.to_sym] || 0) + 1 if counts.key?(status.to_sym)

    messages << {
      id: row["id"],
      data: row["data"] || "",
      status: display_status,
      attempts: attempts,
      error: row["error"] || "",
      created_at: row["created_at"] || ""
    }
  end

  response.json({
    topic: "gallery-tasks",
    messages: messages,
    counts: counts
  })
end

# ── Consume — process the next pending message ────────────────

Tina4::Router.post("/api/gallery/queue/consume") do |request, response|
  db = _gallery_queue_db
  now = _gallery_queue_now

  row = db.fetch_one(
    "SELECT * FROM tina4_queue WHERE topic = ? AND status = 'pending' AND available_at <= ? ORDER BY priority DESC, id ASC",
    ["gallery-tasks", now]
  )

  if row.nil?
    response.json({ consumed: false, message: "No pending messages to consume" })
  else
    db.execute(
      "UPDATE tina4_queue SET status = 'completed', completed_at = ? WHERE id = ? AND status = 'pending'",
      [now, row["id"]]
    )
    response.json({ consumed: true, job_id: row["id"], data: row["data"] })
  end
end

# ── Fail — deliberately fail the next pending message ─────────

Tina4::Router.post("/api/gallery/queue/fail") do |request, response|
  db = _gallery_queue_db
  now = _gallery_queue_now

  row = db.fetch_one(
    "SELECT * FROM tina4_queue WHERE topic = ? AND status = 'pending' AND available_at <= ? ORDER BY priority DESC, id ASC",
    ["gallery-tasks", now]
  )

  if row.nil?
    response.json({ failed: false, message: "No pending messages to fail" })
  else
    db.execute(
      "UPDATE tina4_queue SET status = 'failed', error = ?, attempts = attempts + 1 WHERE id = ?",
      ["Deliberately failed via gallery demo", row["id"]]
    )
    response.json({ failed: true, job_id: row["id"], data: row["data"] })
  end
end

# ── Retry — re-queue failed messages ──────────────────────────

Tina4::Router.post("/api/gallery/queue/retry") do |request, response|
  db = _gallery_queue_db
  now = _gallery_queue_now

  db.execute(
    "UPDATE tina4_queue SET status = 'pending', available_at = ? WHERE topic = ? AND status = 'failed' AND attempts < ?",
    [now, "gallery-tasks", GALLERY_QUEUE_MAX_RETRIES]
  )

  row = db.fetch_one(
    "SELECT COUNT(*) as cnt FROM tina4_queue WHERE topic = ? AND status = 'pending'",
    ["gallery-tasks"]
  )
  retried = row ? row["cnt"].to_i : 0

  response.json({ retried: retried })
end
