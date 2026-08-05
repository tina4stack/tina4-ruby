# frozen_string_literal: true

require "spec_helper"
require "tina4/queue"

# AMQP URL vhost contract (RabbitMQ URI spec).
#
# THE VHOST IS THE PATH SEGMENT, URL-DECODED, WITH NO LEADING SLASH.
#
# REGRESSION. All four frameworks used to prepend "/", so
# amqp://guest:guest@rabbit:5672/orders asked the broker for a virtual host
# literally named "/orders". No broker has that one - it is named "orders" - so
# every publish failed against a named vhost, which is the ordinary
# multi-tenant setup and the form every RabbitMQ tutorial shows.
#
# Nothing caught it because the only URL shape that worked was the one carrying
# NO vhost, which is what every test and every dev box used - and because the
# live-integration tests reimplemented the parser, bug included, so they agreed
# with the framework instead of checking it.
#
# Pure parsing of a string: no broker, no socket, no double.
RSpec.describe "AMQP URL vhost contract" do
  def vhost(url)
    Tina4::Queue.parse_amqp_url(url)[:vhost]
  end

  it "reads the vhost as the path segment, not a slash-prefixed name" do
    # POSITIVE: the name the broker actually has.
    expect(vhost("amqp://guest:guest@rabbit:5672/orders")).to eq("orders")
    # NEGATIVE: and specifically NOT the old slash-prefixed name.
    expect(vhost("amqp://guest:guest@rabbit:5672/orders")).not_to eq("/orders")
  end

  it "percent-decodes the vhost" do
    # The DEFAULT vhost is named "/", which cannot appear literally in a path,
    # so the spec spells it "%2f". Undecoded it asks for a vhost named "%2f".
    expect(vhost("amqp://rabbit:5672/%2f")).to eq("/")
    expect(vhost("amqp://rabbit:5672/a%2Fb")).to eq("a/b")
    # "+" is NOT a space here: this is a path, not a form body.
    expect(vhost("amqp://rabbit:5672/a+b")).to eq("a+b")
  end

  it "leaves the caller's default when no vhost is given" do
    expect(vhost("amqp://rabbit:5672")).to be_nil
    # A bare trailing slash is "not specified" too - see the deviation note in
    # queue.rb. Reading it as the empty vhost name would break a working
    # amqp://host:5672/ for no benefit.
    expect(vhost("amqp://rabbit:5672/")).to be_nil
  end

  it "still parses the credentials and host:port alongside it" do
    cfg = Tina4::Queue.parse_amqp_url("amqps://user:pass@rabbit.example.com:5671/orders")
    expect(cfg[:username]).to eq("user")
    expect(cfg[:password]).to eq("pass")
    expect(cfg[:host]).to eq("rabbit.example.com")
    expect(cfg[:port]).to eq(5671)
    expect(cfg[:vhost]).to eq("orders")
  end
end
