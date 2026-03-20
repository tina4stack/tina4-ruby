# frozen_string_literal: true

module Tina4
  # Context object passed to each service handler, giving it control
  # over its own lifecycle and metadata.
  class ServiceContext
    attr_accessor :running, :last_run, :name, :error_count

    def initialize(name)
      @running = true
      @last_run = nil
      @name = name
      @error_count = 0
    end
  end

  # In-process service runner using Ruby threads.
  # Supports cron schedules, simple intervals, and daemon (self-looping) handlers.
  #
  #   Tina4::ServiceRunner.register("cleanup", timing: "*/5 * * * *") { |ctx| ... }
  #   Tina4::ServiceRunner.register("poller", interval: 10) { |ctx| ... }
  #   Tina4::ServiceRunner.register("worker", daemon: true) { |ctx| while ctx.running; ...; end }
  #   Tina4::ServiceRunner.start
  #
  class ServiceRunner
    @registry = {}   # name => { handler:, options: }
    @threads  = {}   # name => Thread
    @contexts = {}   # name => ServiceContext
    @mutex    = Mutex.new

    class << self
      # ── Registration ──────────────────────────────────────────────────

      # Register a named service with options and a handler block (or callable).
      #
      # Options:
      #   timing:      cron expression, e.g. "*/5 * * * *"
      #   interval:    run every N seconds
      #   daemon:      boolean — handler manages its own loop
      #   max_retries: restart limit on crash (default 3)
      def register(name, handler = nil, options = {}, &block)
        callable = handler || block
        raise ArgumentError, "provide a handler or block for service '#{name}'" unless callable

        @mutex.synchronize do
          @registry[name.to_s] = { handler: callable, options: options }
        end
        Tina4::Log.debug("Service registered: #{name}")
      end

      # Auto-discover service files from a directory.
      # Each file should call Tina4.service or Tina4::ServiceRunner.register.
      def discover(service_dir = nil)
        service_dir ||= ENV["TINA4_SERVICE_DIR"] || "src/services"
        full_dir = File.expand_path(service_dir, Tina4.root_dir || Dir.pwd)
        return unless Dir.exist?(full_dir)

        Dir.glob(File.join(full_dir, "**/*.rb")).sort.each do |file|
          begin
            load file
            Tina4::Log.debug("Service discovered: #{file}")
          rescue => e
            Tina4::Log.error("Failed to load service #{file}: #{e.message}")
          end
        end
      end

      # ── Lifecycle ─────────────────────────────────────────────────────

      # Start all registered services, or a specific one by name.
      def start(name = nil)
        targets = if name
                    entry = @registry[name.to_s]
                    raise KeyError, "service '#{name}' not registered" unless entry
                    { name.to_s => entry }
                  else
                    @registry.dup
                  end

        targets.each do |svc_name, entry|
          next if @threads[svc_name]&.alive?

          ctx = ServiceContext.new(svc_name)
          @mutex.synchronize { @contexts[svc_name] = ctx }

          thread = Thread.new { run_loop(svc_name, entry[:handler], entry[:options], ctx) }
          thread.name = "tina4-service-#{svc_name}" if thread.respond_to?(:name=)
          @mutex.synchronize { @threads[svc_name] = thread }

          Tina4::Log.info("Service started: #{svc_name}")
        end
      end

      # Stop all running services, or a specific one by name.
      def stop(name = nil)
        targets = if name
                    ctx = @contexts[name.to_s]
                    ctx ? { name.to_s => ctx } : {}
                  else
                    @contexts.dup
                  end

        targets.each do |svc_name, ctx|
          ctx.running = false
          Tina4::Log.info("Service stopping: #{svc_name}")
        end

        # Join threads with a timeout so we don't hang forever
        targets.each_key do |svc_name|
          thread = @threads[svc_name]
          next unless thread

          thread.join(5)
          @mutex.synchronize do
            @threads.delete(svc_name)
            @contexts.delete(svc_name)
          end
        end
      end

      # List all registered services with their status.
      def list
        @registry.map do |name, entry|
          ctx = @contexts[name]
          {
            name: name,
            options: entry[:options],
            running: ctx&.running == true && @threads[name]&.alive? == true,
            last_run: ctx&.last_run,
            error_count: ctx&.error_count || 0
          }
        end
      end

      # Check if a specific service is currently running.
      def running?(name)
        ctx = @contexts[name.to_s]
        ctx&.running == true && @threads[name.to_s]&.alive? == true
      end

      # Remove all registrations and stop all services. Useful for tests.
      def clear!
        stop
        @mutex.synchronize do
          @registry.clear
          @threads.clear
          @contexts.clear
        end
      end

      # ── Cron matching ─────────────────────────────────────────────────

      # Check whether a 5-field cron pattern matches a given Time.
      # Fields: minute hour day_of_month month day_of_week
      def match_cron?(pattern, time = Time.now)
        fields = pattern.strip.split(/\s+/)
        return false unless fields.length == 5

        minute, hour, dom, month, dow = fields

        parse_cron_field(minute, time.min, 59) &&
          parse_cron_field(hour, time.hour, 23) &&
          parse_cron_field(dom, time.day, 31) &&
          parse_cron_field(month, time.month, 12) &&
          parse_cron_field(dow, time.wday, 7)
      end

      private

      # ── Run loop ──────────────────────────────────────────────────────

      def run_loop(name, handler, options, ctx)
        max_retries = options.fetch(:max_retries, 3)
        sleep_interval = (ENV["TINA4_SERVICE_SLEEP"] || 1).to_f

        if options[:daemon]
          run_daemon(name, handler, options, ctx, max_retries)
        elsif options[:timing]
          run_cron(name, handler, options[:timing], ctx, max_retries, sleep_interval)
        elsif options[:interval]
          run_interval(name, handler, options[:interval], ctx, max_retries)
        else
          # One-shot: run handler once
          run_handler(name, handler, ctx)
        end
      rescue => e
        Tina4::Log.error("Service '#{name}' loop crashed: #{e.message}")
      ensure
        ctx.running = false
      end

      # Daemon mode: handler manages its own loop, we just call it.
      def run_daemon(name, handler, _options, ctx, max_retries)
        retries = 0
        while ctx.running && retries <= max_retries
          begin
            run_handler(name, handler, ctx)
            break # normal exit
          rescue => e
            retries += 1
            ctx.error_count += 1
            Tina4::Log.error("Service '#{name}' daemon crashed (#{retries}/#{max_retries}): #{e.message}")
            break if retries > max_retries
            sleep(1) if ctx.running
          end
        end
      end

      # Cron mode: check every sleep_interval seconds, fire when pattern matches.
      def run_cron(name, handler, pattern, ctx, max_retries, sleep_interval)
        last_fired_minute = nil
        retries = 0

        while ctx.running
          now = Time.now
          current_minute = [now.year, now.month, now.day, now.hour, now.min]

          if match_cron?(pattern, now) && current_minute != last_fired_minute
            last_fired_minute = current_minute
            begin
              run_handler(name, handler, ctx)
              retries = 0
            rescue => e
              retries += 1
              ctx.error_count += 1
              Tina4::Log.error("Service '#{name}' cron failed (#{retries}/#{max_retries}): #{e.message}")
              break if retries > max_retries
            end
          end

          sleep(sleep_interval) if ctx.running
        end
      end

      # Interval mode: simple sleep(N) between invocations.
      def run_interval(name, handler, interval, ctx, max_retries)
        retries = 0

        while ctx.running
          begin
            run_handler(name, handler, ctx)
            retries = 0
          rescue => e
            retries += 1
            ctx.error_count += 1
            Tina4::Log.error("Service '#{name}' interval failed (#{retries}/#{max_retries}): #{e.message}")
            break if retries > max_retries
          end

          # Sleep in small increments so stop is responsive
          remaining = interval.to_f
          while remaining > 0 && ctx.running
            nap = [remaining, 0.25].min
            sleep(nap)
            remaining -= nap
          end
        end
      end

      # Execute the handler and update context.
      def run_handler(_name, handler, ctx)
        handler.call(ctx)
        ctx.last_run = Time.now
      end

      # ── Cron field parsing ────────────────────────────────────────────

      # Parse a single cron field and check if `current` matches.
      #   *       — always matches
      #   */N     — every N (step)
      #   1,5,10  — list of values
      #   1-5     — range
      #   N       — exact value
      def parse_cron_field(field, current, max)
        return true if field == "*"

        # Step: */N
        if field.start_with?("*/")
          step = field[2..].to_i
          return false if step <= 0
          return (current % step).zero?
        end

        # List: 1,5,10
        if field.include?(",")
          values = field.split(",").map(&:to_i)
          return values.include?(current)
        end

        # Range: 1-5
        if field.include?("-")
          parts = field.split("-")
          low = parts[0].to_i
          high = parts[1].to_i
          return (low..high).include?(current)
        end

        # Exact value
        field.to_i == current
      end
    end
  end
end
