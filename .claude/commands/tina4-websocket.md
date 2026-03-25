# Set Up Tina4 WebSocket Communication

Create real-time WebSocket endpoints using the built-in RFC 6455 implementation.

## Instructions

1. Register WebSocket route handlers
2. Use the connection manager for broadcasting
3. Integrate with the main server

## WebSocket Route (`src/routes/ws.rb`)

```ruby
require "tina4/websocket"
require "json"

ws = Tina4::WebSocketServer.new

ws.route "/ws/chat" do |conn, message|
  data = JSON.parse(message)

  if data["type"] == "join"
    conn.manager.broadcast(
      JSON.generate({ "type" => "joined", "user" => data["user"] }),
      path: "/ws/chat"
    )
  elsif data["type"] == "message"
    conn.manager.broadcast(
      JSON.generate({ "type" => "message", "user" => data["user"], "text" => data["text"] }),
      path: "/ws/chat"
    )
  end
end

ws.route "/ws/notifications" do |conn, message|
  # Handle notification subscriptions
end
```

## Connection Manager

```ruby
require "tina4/websocket"

manager = Tina4::WebSocketManager.new

# Broadcast to all connections on a path
manager.broadcast("Hello everyone!", path: "/ws/chat")

# Send to a specific connection
conn = manager.get_by_id(connection_id)
if conn
  conn.send("Private message")
end

# Get all connections on a path
connections = manager.get_by_path("/ws/chat")

# Connection count
count = manager.connections.length
```

## Client-Side (JavaScript)

```javascript
const ws = new WebSocket("ws://localhost:7145/ws/chat");

ws.onopen = () => {
    ws.send(JSON.stringify({ type: "join", user: "Alice" }));
};

ws.onmessage = (event) => {
    const data = JSON.parse(event.data);
    console.log(data);
};

ws.onclose = () => console.log("Disconnected");
```

## WebSocket Features

```ruby
# Connection properties
conn.id          # Unique connection ID
conn.path        # Route path (e.g., "/ws/chat")
conn.ip          # Client IP address
conn.closed?     # Boolean -- is connection closed?

# Send/receive
conn.send("text message")
conn.send_binary(binary_data)
conn.close(code: 1000, reason: "Normal closure")

# Frame types supported
# - Text (opcode 0x1)
# - Binary (opcode 0x2)
# - Close (opcode 0x8)
# - Ping (opcode 0x9) -- auto-responded with Pong
# - Pong (opcode 0xA)
# - Fragmented messages (auto-reassembled)
```

## Environment Config

```bash
TINA4_WS_MAX_FRAME_SIZE=1048576    # Max frame size in bytes (default 1MB)
TINA4_WS_MAX_CONNECTIONS=1000      # Max concurrent connections
```

## Key Rules

- WebSocket routes go in `src/routes/` like HTTP routes
- Always use JSON for structured messages
- Use path-based routing to separate concerns (chat, notifications, etc.)
- The server handles ping/pong automatically -- no keepalive code needed
- Connection cleanup is automatic when clients disconnect
