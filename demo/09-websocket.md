# WebSocket

Tina4 Ruby includes a built-in WebSocket implementation that handles the HTTP upgrade handshake, frame parsing/building, and connection management. It supports text messages, ping/pong, and broadcasting.

## Setting Up WebSocket

```ruby
require "tina4"

ws = Tina4::WebSocket.new

# Handle new connections
ws.on(:open) do |connection|
  puts "Client connected: #{connection.id}"
  connection.send_text("Welcome! Your ID: #{connection.id}")
end

# Handle incoming messages
ws.on(:message) do |connection, message|
  puts "Received from #{connection.id}: #{message}"

  # Echo back
  connection.send_text("Echo: #{message}")

  # Broadcast to all other clients
  ws.broadcast("#{connection.id} says: #{message}", exclude: connection.id)
end

# Handle disconnections
ws.on(:close) do |connection|
  puts "Client disconnected: #{connection.id}"
end

# Handle errors
ws.on(:error) do |connection, error|
  puts "Error from #{connection.id}: #{error.message}"
end
```

## WebSocket Upgrade Detection

The WebSocket server detects upgrade requests via the `Upgrade: websocket` header.

```ruby
# In a Rack app or middleware
ws.upgrade?(env)
# => true if HTTP_UPGRADE header is "websocket"

# Perform the upgrade
ws.handle_upgrade(env, socket)
# Sends 101 Switching Protocols, starts reading frames in a background thread
```

## Broadcasting

```ruby
# Send to all connected clients
ws.broadcast("Server announcement: maintenance in 5 minutes")

# Send to all except one client
ws.broadcast("User joined", exclude: connection.id)
```

## Connection Management

```ruby
# All active connections
ws.connections
# => { "abc123..." => WebSocketConnection, ... }

# Send to a specific connection
ws.connections["abc123"].send_text("Private message")

# Close a connection
ws.connections["abc123"].close(code: 1000, reason: "Goodbye")
```

## WebSocketConnection API

```ruby
connection.id               # => unique hex string
connection.send_text(msg)   # send a text frame
connection.send_pong(data)  # respond to a ping
connection.close(code: 1000, reason: "Normal closure")
```

## Chat Room Example

```ruby
ws = Tina4::WebSocket.new
usernames = {}

ws.on(:open) do |conn|
  usernames[conn.id] = "Anonymous"
  conn.send_text('{"type":"system","message":"Welcome! Send {\"type\":\"setName\",\"name\":\"YourName\"} to set your name."}')
end

ws.on(:message) do |conn, message|
  data = JSON.parse(message) rescue {}

  case data["type"]
  when "setName"
    old_name = usernames[conn.id]
    usernames[conn.id] = data["name"]
    ws.broadcast(JSON.generate({ type: "system", message: "#{old_name} is now #{data['name']}" }))

  when "chat"
    name = usernames[conn.id]
    ws.broadcast(JSON.generate({ type: "chat", user: name, message: data["message"] }))
  end
end

ws.on(:close) do |conn|
  name = usernames.delete(conn.id)
  ws.broadcast(JSON.generate({ type: "system", message: "#{name} left" }))
end
```

## Frame Protocol

The implementation handles standard WebSocket framing:
- Opcode `0x1` -- Text frame
- Opcode `0x8` -- Close frame
- Opcode `0x9` -- Ping (auto-responds with pong)
- Supports masked frames (client-to-server)
- Supports payloads up to 2^63 bytes
