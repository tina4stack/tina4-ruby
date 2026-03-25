# Set Up Tina4 Email (Send & Receive)

Send and read emails using the built-in Messenger module (SMTP + IMAP, stdlib only).

## Instructions

1. Configure SMTP/IMAP in `.env`
2. Use `Messenger` to send emails
3. Use `Messenger` to read emails via IMAP

## .env

```bash
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USERNAME=you@gmail.com
SMTP_PASSWORD=app-password-here
SMTP_FROM=you@gmail.com

IMAP_HOST=imap.gmail.com
IMAP_PORT=993
```

## Send Email

```ruby
require "tina4/messenger"

mail = Tina4::Messenger.new

# Plain text
mail.send(to: "user@example.com", subject: "Hello", body: "Plain text message")

# HTML
mail.send(
  to: "user@example.com",
  subject: "Welcome",
  body: "<h1>Welcome!</h1><p>Thanks for signing up.</p>",
  html: true
)

# With attachment
mail.send(
  to: "user@example.com",
  subject: "Report",
  body: "See attached.",
  attachments: ["/path/to/report.pdf"]
)

# Multiple recipients, CC, BCC, Reply-To
mail.send(
  to: ["alice@test.com", "bob@test.com"],
  subject: "Team Update",
  body: "...",
  cc: ["manager@test.com"],
  bcc: ["archive@test.com"],
  reply_to: "noreply@test.com"
)

# Binary attachment
mail.send(
  to: "user@example.com",
  subject: "Image",
  body: "Here's the image.",
  attachments: [{ filename: "photo.png", data: image_bytes, mime: "image/png" }]
)
```

## Read Email (IMAP)

```ruby
require "tina4/messenger"

mail = Tina4::Messenger.new

# Get inbox messages (default limit=10)
messages = mail.inbox(limit: 20)

# Get unread count
count = mail.unread

# Read a specific message by UID
msg = mail.read(uid: "123")
# Returns: {uid, subject, from, to, cc, date, body_text, body_html, attachments, headers}

# Search
results = mail.search(subject: "invoice", sender: "billing@", since: "2024-01-01", unseen_only: true)

# Mark as read/unread
mail.mark_read("123")
mail.mark_unread("123")

# Delete
mail.delete("123")

# List folders
folders = mail.folders
```

## Send from a Route

```ruby
require "tina4/router"
require "tina4/messenger"

Tina4::Router.post "/api/contact" do |request, response|
  mail = Tina4::Messenger.new
  mail.send(
    to: "support@myapp.com",
    subject: "Contact: #{request.body['subject']}",
    body: request.body["message"],
    reply_to: request.body["email"]
  )
  response.json({ "sent" => true })
end
```

## With Templates

```ruby
require "tina4/messenger"
require "tina4/template"

html = Tina4::Template.render("emails/welcome.twig", { "name" => "Alice", "link" => "https://myapp.com" })
mail = Tina4::Messenger.new
mail.send(to: "alice@test.com", subject: "Welcome!", body: html, html: true)
```

## Test Connection

```ruby
mail = Tina4::Messenger.new
mail.test_connection        # Test SMTP
mail.test_imap_connection   # Test IMAP
```

## Key Rules

- For slow sends (bulk email), push to a Queue and process asynchronously
- Use app passwords for Gmail (not your real password)
- SMTP uses STARTTLS on port 587, SSL on port 465
- IMAP always uses SSL
- All email handling uses Ruby stdlib (`net/smtp`, `net/imap`) -- zero dependencies
