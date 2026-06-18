# frozen_string_literal: true

require "securerandom"
require "json"

module Tina4
  # Zero-dependency fake data generator with deterministic seeding.
  # Uses Ruby's built-in Random for reproducible data generation.
  #
  # @example
  #   fake = Tina4::FakeData.new(seed: 42)
  #   fake.name        # => "Sarah Johnson"
  #   fake.email       # => "sarah.johnson123@example.com"
  #   fake.integer(1, 100)
  class FakeData
    FIRST_NAMES = %w[
      James Mary Robert Patricia John Jennifer Michael Linda David Elizabeth
      William Barbara Richard Susan Joseph Jessica Thomas Sarah Charles Karen
      Christopher Lisa Daniel Nancy Matthew Betty Anthony Margaret Mark Sandra
      Donald Ashley Steven Dorothy Paul Kimberly Andrew Emily Joshua Donna
      Kenneth Michelle Kevin Carol Brian Amanda George Melissa Timothy Deborah
      Ronald Stephanie Edward Rebecca Jason Sharon Jeffrey Laura Ryan Cynthia
      Jacob Kathleen Gary Amy Nicholas Angela Eric Shirley Jonathan Anna
      Stephen Brenda Larry Pamela Justin Emma Scott Nicole Brandon Helen
      Benjamin Samantha Samuel Katherine Raymond Christine Gregory Debra
      Frank Rachel Alexander Carolyn Patrick Janet Jack Catherine Andre Aisha
      Wei Yuki Carlos Fatima Raj Priya Mohammed Sophia Liam Olivia Noah Ava
      Ethan Mia Lucas Isabella Mason Charlotte Logan Amelia Aiden Harper
    ].freeze

    LAST_NAMES = %w[
      Smith Johnson Williams Brown Jones Garcia Miller Davis Rodriguez Martinez
      Hernandez Lopez Gonzalez Wilson Anderson Thomas Taylor Moore Jackson Martin
      Lee Perez Thompson White Harris Sanchez Clark Ramirez Lewis Robinson Walker
      Young Allen King Wright Scott Torres Nguyen Hill Flores Green Adams Nelson
      Baker Hall Rivera Campbell Mitchell Carter Roberts Gomez Phillips Evans
      Turner Diaz Parker Cruz Edwards Collins Reyes Stewart Morris Morales
      Murphy Cook Rogers Gutierrez Ortiz Morgan Cooper Peterson Bailey Reed
      Kelly Howard Ramos Kim Cox Ward Richardson Watson Brooks Chavez Wood
      James Bennett Gray Mendoza Ruiz Hughes Price Alvarez Castillo Sanders
      Patel Müller Nakamura Singh Chen Silva Ali Okafor
    ].freeze

    WORDS = %w[
      the be to of and a in that have it for not on with he as you do at
      this but his by from they we say her she or an will my one all would
      there their what so up out if about who get which go me when make can
      like time no just him know take people into year your good some could
      them see other than then now look only come its over think also back
      after use two how our work first well way even new want because any
      these give day most us great small large every found still between name
      should home big end along each much both help line turn move thing right
      same old better point long real system data report order product service
      customer account payment record total status market world company project
      team value process business group result information development management
      quality performance technology support research design program network
    ].freeze

    CITIES = [
      "New York", "London", "Tokyo", "Paris", "Berlin", "Sydney", "Toronto",
      "Mumbai", "São Paulo", "Cairo", "Lagos", "Dubai", "Singapore",
      "Hong Kong", "Seoul", "Mexico City", "Bangkok", "Istanbul", "Moscow",
      "Rome", "Barcelona", "Amsterdam", "Nairobi", "Cape Town", "Johannesburg",
      "Buenos Aires", "Lima", "Santiago", "Jakarta", "Manila", "Kuala Lumpur",
      "Auckland", "Vancouver", "Chicago", "San Francisco", "Los Angeles",
      "Miami", "Boston", "Seattle", "Denver"
    ].freeze

    COUNTRIES = [
      "United States", "United Kingdom", "Canada", "Australia", "Germany",
      "France", "Japan", "Brazil", "India", "South Africa", "Nigeria",
      "Egypt", "Kenya", "Mexico", "Argentina", "Chile", "Colombia", "Spain",
      "Italy", "Netherlands", "Sweden", "Norway", "Denmark", "Finland",
      "Switzerland", "Belgium", "Austria", "New Zealand", "Singapore",
      "South Korea", "Thailand", "Indonesia", "Philippines", "Vietnam",
      "Malaysia", "United Arab Emirates", "Saudi Arabia", "Turkey", "Poland"
    ].freeze

    DOMAINS = %w[
      example.com test.org sample.net demo.io mail.com
      inbox.org webmail.net company.com corp.io biz.net
    ].freeze

    STREETS = %w[Main Oak Pine Maple Cedar Elm Park Lake Hill River Church Market King Queen High].freeze
    STREET_TYPES = %w[Street Avenue Road Drive Lane Boulevard Way Place].freeze
    COMPANY_WORDS = %w[Tech Global Apex Nova Core Prime Next Blue Bright Smart Swift Peak Fusion Pulse Vertex].freeze
    COMPANY_SUFFIXES = %w[Inc Corp Ltd LLC Group Solutions Systems Labs].freeze
    JOB_TITLES = [
      "Software Engineer", "Product Manager", "Designer", "Data Analyst",
      "DevOps Engineer", "CEO", "CTO", "Sales Manager", "Marketing Lead",
      "Accountant", "Operations Manager", "QA Engineer", "UX Researcher",
      "Support Specialist", "HR Manager", "Technical Writer"
    ].freeze
    CURRENCIES = %w[USD EUR GBP JPY CAD AUD CHF ZAR INR CNY].freeze
    CREDIT_CARD_PREFIXES = %w[4111 4242 5500 5105].freeze

    def initialize(seed: nil)
      @rng = seed ? Random.new(seed) : Random.new
    end

    # Static factory — create a seeded FakeData instance.
    #   fake = FakeData.seed(42)
    #   fake.name  # deterministic
    def self.seed(seed)
      new(seed: seed)
    end

    def first_name
      FIRST_NAMES[@rng.rand(FIRST_NAMES.length)]
    end

    def last_name
      LAST_NAMES[@rng.rand(LAST_NAMES.length)]
    end

    def name
      "#{first_name} #{last_name}"
    end

    def email(from_name: nil)
      if from_name
        local = from_name.downcase.split.join(".")
      else
        local = "#{first_name.downcase}.#{last_name.downcase}"
      end
      local += @rng.rand(1..999).to_s
      "#{local}@#{DOMAINS[@rng.rand(DOMAINS.length)]}"
    end

    def phone
      area = @rng.rand(200..999)
      mid = @rng.rand(100..999)
      tail = @rng.rand(1000..9999)
      "+1 (#{area}) #{mid}-#{tail}"
    end

    def sentence(words: 6)
      w = Array.new(words) { WORDS[@rng.rand(WORDS.length)] }
      w[0] = w[0].capitalize
      "#{w.join(' ')}."
    end

    def paragraph(sentences: 3)
      Array.new(sentences) { sentence(words: @rng.rand(5..12)) }.join(" ")
    end

    def text(max_length: 200)
      t = paragraph(sentences: 2)
      t.length > max_length ? t[0...max_length] : t
    end

    def word
      WORDS[@rng.rand(WORDS.length)]
    end

    def slug(words: 3)
      Array.new(words) { WORDS[@rng.rand(WORDS.length)] }.join("-")
    end

    def url
      "https://#{DOMAINS[@rng.rand(DOMAINS.length)]}/#{slug}"
    end

    def integer(min: 0, max: 10_000)
      @rng.rand(min..max)
    end

    def numeric(min: 0.0, max: 1000.0, decimals: 2)
      val = min + @rng.rand * (max - min)
      val.round(decimals)
    end

    def boolean
      @rng.rand(2)
    end

    def datetime(start_year: 2020, end_year: 2026)
      start_time = Time.new(start_year, 1, 1)
      end_time = Time.new(end_year, 12, 31, 23, 59, 59)
      delta = (end_time - start_time).to_i
      Time.at(start_time.to_i + @rng.rand(0..delta))
    end

    def date(start_year: 2020, end_year: 2026)
      datetime(start_year: start_year, end_year: end_year).strftime("%Y-%m-%d")
    end

    def timestamp(start_year: 2020, end_year: 2026)
      datetime(start_year: start_year, end_year: end_year).strftime("%Y-%m-%d %H:%M:%S")
    end

    def blob(size: 64)
      SecureRandom.random_bytes(size)
    end

    def json_data(keys: nil)
      if keys
        keys.each_with_object({}) { |k, h| h[k] = word }
      else
        n = @rng.rand(2..5)
        n.times.each_with_object({}) { |_, h| h[word] = word }
      end
    end

    def choice(items)
      items[@rng.rand(items.length)]
    end

    def city
      CITIES[@rng.rand(CITIES.length)]
    end

    def country
      COUNTRIES[@rng.rand(COUNTRIES.length)]
    end

    def address
      "#{@rng.rand(1..9999)} #{STREETS[@rng.rand(STREETS.length)]} #{STREET_TYPES[@rng.rand(STREET_TYPES.length)]}"
    end

    def zip_code
      @rng.rand(10_000..99_999).to_s
    end

    def company
      w1 = COMPANY_WORDS[@rng.rand(COMPANY_WORDS.length)]
      w2 = COMPANY_WORDS[@rng.rand(COMPANY_WORDS.length)]
      suffix = COMPANY_SUFFIXES[@rng.rand(COMPANY_SUFFIXES.length)]
      "#{w1}#{w2} #{suffix}"
    end

    def job_title
      JOB_TITLES[@rng.rand(JOB_TITLES.length)]
    end

    def currency
      CURRENCIES[@rng.rand(CURRENCIES.length)]
    end

    def ip_address
      "#{@rng.rand(1..255)}.#{@rng.rand(0..255)}.#{@rng.rand(0..255)}.#{@rng.rand(1..254)}"
    end

    # Generate a fake credit card number (test numbers only, e.g. 4111...).
    def credit_card
      prefix = CREDIT_CARD_PREFIXES[@rng.rand(CREDIT_CARD_PREFIXES.length)]
      rest = Array.new(12) { @rng.rand(0..9) }.join
      prefix + rest
    end

    def color_hex
      "#%06x" % @rng.rand(0..0xFFFFFF)
    end

    def uuid
      h = Array.new(32) { "0123456789abcdef"[@rng.rand(16)] }.join
      "#{h[0..7]}-#{h[8..11]}-#{h[12..15]}-#{h[16..19]}-#{h[20..31]}"
    end

    def password(length: 16)
      chars = [*"a".."z", *"A".."Z", *"0".."9"]
      Array.new(length) { chars[@rng.rand(chars.length)] }.join
    end

    # Run a generator block `count` times and return the results.
    def run(count = 1, &block)
      Array.new(count) { block.call }
    end

    # Generate appropriate data based on field definition and column name.
    def for_field(field_def, column_name = nil)
      col = (column_name || "").to_s.downcase
      type = field_def[:type]

      # Skip auto-increment primary keys
      return nil if field_def[:primary_key] && field_def[:auto_increment]

      case type
      when :integer
        return integer(min: 18, max: 85) if col.include?("age")
        return integer(min: 1950, max: 2026) if col.include?("year")
        return integer(min: 1, max: 100) if col =~ /quantity|qty|count/
        return boolean if col =~ /active|enabled|visible|^is_/
        return integer(min: 1, max: 10) if col =~ /rating|score/
        integer(min: 1, max: 10_000)

      when :float, :decimal
        decimals = field_def[:scale] || 2
        return numeric(min: 0.01, max: 9999.99, decimals: decimals) if col =~ /price|cost|amount|total|fee/
        return numeric(min: 0.0, max: 100.0, decimals: decimals) if col =~ /rate|percent|ratio/
        return numeric(min: -90.0, max: 90.0, decimals: 6) if col.include?("lat")
        return numeric(min: -180.0, max: 180.0, decimals: 6) if col =~ /lon|lng/
        numeric(min: 0.0, max: 10_000.0, decimals: decimals)

      when :date
        date

      when :datetime, :timestamp
        timestamp

      when :boolean
        boolean

      when :blob
        blob

      when :json
        json_data

      when :string, :text
        max_len = field_def[:length] || 255
        val = generate_string_for(col, max_len)
        val.length > max_len ? val[0...max_len] : val

      else
        word
      end
    end

    private

    def generate_string_for(col, max_len)
      return email[0...max_len] if col.include?("email")
      return name[0...max_len] if %w[name full_name fullname display_name].include?(col)
      return first_name[0...max_len] if col.include?("first") && col.include?("name")
      return last_name[0...max_len] if col.include?("last") && col.include?("name")
      return last_name[0...max_len] if col =~ /surname|family_name/
      return phone[0...max_len] if col =~ /phone|tel|mobile|cell/
      return url[0...max_len] if col =~ /url|website|link|href/
      return address[0...max_len] if col =~ /address|street/
      return city[0...max_len] if col =~ /city|town/
      return country[0...max_len] if col.include?("country")
      return zip_code[0...max_len] if col =~ /zip|postal/
      return company[0...max_len] if col =~ /company|organization|org/
      return color_hex[0...max_len] if col =~ /color|colour/
      return uuid[0...max_len] if col =~ /uuid|guid/
      return slug[0...max_len] if col.include?("slug")
      return sentence(words: @rng.rand(3..6)).chomp(".")[0...max_len] if col =~ /title|subject|heading/
      return text(max_length: max_len) if col =~ /description|summary|bio|about/
      return paragraph(sentences: 2)[0...max_len] if col =~ /content|body|text|note|comment/
      return choice(%w[active inactive pending archived])[0...max_len] if col.include?("status")
      return choice(%w[standard premium basic enterprise custom])[0...max_len] if col =~ /type|category|kind/
      return word[0...max_len] if col =~ /tag|label/
      return password(length: [16, max_len].min) if col =~ /password|pass|secret/
      return password(length: [32, max_len].min) if col =~ /token|key|hash/
      return "#{first_name.downcase}#{@rng.rand(1..99)}"[0...max_len] if col =~ /username|user_name|login/

      sentence(words: @rng.rand(2..5)).chomp(".")[0...max_len]
    end
  end

  # Result of a seed run — +{seeded, failed, errors}+.
  #
  # Mirrors the Python master's +SeedSummary(int)+. Ruby has no int subclass,
  # but the OLD seed helpers returned the inserted count as an Integer and
  # specs assert on it (+expect(count).to eq(5)+). To keep that contract
  # intact while exposing the new struct, +SeedSummary+ defines +to_i+, +==+
  # (against an Integer or another SeedSummary), +to_int+ (implicit coercion)
  # and Hash-style read access (+summary[:seeded]+, +to_h+) so it behaves like
  # the seeded count where an Integer is expected and like the struct
  # everywhere else.
  #
  # +errors+ is a list of +{ row: <0-based index>, message: <str> }+ hashes
  # describing every skipped row.
  class SeedSummary
    attr_reader :seeded, :failed, :errors

    def initialize(seeded: 0, failed: 0, errors: nil)
      @seeded = seeded.to_i
      @failed = failed.to_i
      @errors = errors || []
    end

    # Integer value == seeded (preserves the pre-overhaul count contract).
    def to_i
      @seeded
    end
    alias to_int to_i

    def to_h
      { seeded: @seeded, failed: @failed, errors: @errors }
    end
    alias to_hash to_h

    # Hash-style read access: summary[:seeded] / summary["failed"].
    def [](key)
      to_h[key.to_sym]
    end

    # Compare equal to a bare Integer (the seeded count) OR another summary.
    def ==(other)
      case other
      when Integer then @seeded == other
      when SeedSummary then to_h == other.to_h
      when Hash then to_h == other
      else false
      end
    end

    def eql?(other)
      other.is_a?(SeedSummary) && to_h == other.to_h
    end

    def hash
      to_h.hash
    end

    # Arithmetic / ordering against Integers so existing numeric assertions
    # (e.g. +be >= 1+, +count + 1+) keep working.
    def coerce(other)
      [other, @seeded]
    end

    def <=>(other)
      @seeded <=> (other.is_a?(SeedSummary) ? other.to_i : other)
    end
    include Comparable

    def to_json(*args)
      to_h.to_json(*args)
    end

    def to_s
      "SeedSummary(seeded=#{@seeded}, failed=#{@failed}, errors=#{@errors.inspect})"
    end
    alias inspect to_s
  end

  # Seed an ORM class with auto-generated fake data.
  #
  # Visible-but-resilient: each row is wrapped. On a row failure the cause is
  # logged (with the row index) and the row is skipped — unless +strict: true+,
  # in which case the FIRST failure RE-RAISES. A one-line summary is logged at
  # the end. This replaces both the old crash-prone path and the silent swallow.
  #
  # @param orm_class [Class] ORM subclass (e.g., User, Product)
  # @param count [Integer] number of records to insert
  # @param overrides [Hash] field overrides — static values or lambdas receiving FakeData
  # @param clear [Boolean] delete existing records before seeding (P2)
  # @param seed [Integer, nil] random seed for reproducible data (P3)
  # @param strict [Boolean] re-raise on the first failed row instead of skipping (P1)
  # @return [SeedSummary] +{seeded, failed, errors}+ — also usable as the int count
  #
  # @example
  #   Tina4.seed_orm(User, count: 50)
  #   Tina4.seed_orm(Order, count: 200, overrides: { status: ->(f) { f.choice(%w[pending shipped]) } })
  def self.seed_orm(orm_class, count: 10, overrides: {}, clear: false, seed: nil, strict: false)
    fake = FakeData.new(seed: seed)
    fields = orm_class.field_definitions
    table = orm_class.table_name

    if fields.empty?
      Tina4::Log.error("Seeder: No fields found on #{orm_class.name}")
      return SeedSummary.new
    end

    db = Tina4.database
    unless db
      Tina4::Log.error("Seeder: No database connection. Call Tina4.bind_database(db) first.")
      return SeedSummary.new
    end

    # Idempotency short-circuit (Ruby-specific, additive to the Python master):
    # without an explicit clear, skip when the table already has >= count rows.
    unless clear
      begin
        result = db.fetch_one("SELECT count(*) as cnt FROM #{table}")
        if result && result[:cnt].to_i >= count
          Tina4::Log.info("Seeder: #{table} already has #{result[:cnt]} records, skipping")
          return SeedSummary.new
        end
      rescue => e
        # Table might not exist — fall through and let row inserts surface it.
      end
    end

    _clear_orm(orm_class) if clear

    insert_fields = fields.reject { |name, opts| opts[:primary_key] && opts[:auto_increment] }

    # P4a — resolve FK columns to REAL parent PKs so a child row references an
    # existing parent. Snapshotted once (parents are seeded first by
    # seed_models's topo-sort, so the table is populated by now).
    fk_pools = _foreign_key_pools(orm_class, insert_fields)

    seeded = 0
    failed = 0
    errors = []

    count.times do |i|
      begin
        attrs = {}
        insert_fields.each do |name, field_def|
          if overrides.key?(name)
            val = overrides[name]
            attrs[name] = val.respond_to?(:call) ? val.call(fake) : val
          elsif fk_pools[name] && !fk_pools[name].empty?
            attrs[name] = fake.choice(fk_pools[name])
          else
            generated = fake.for_field(field_def, name)
            attrs[name] = generated unless generated.nil?
          end
        end

        _validate_types(fields, attrs, orm_class.name)

        obj = orm_class.new(attrs)
        # ORM#save returns false (it rolls back internally) instead of raising
        # on a constraint failure — convert that falsy result into a counted
        # failure so it is never reported as success.
        if obj.save
          seeded += 1
        else
          reason = obj.errors.empty? ? "save returned false" : obj.errors.join(", ")
          raise "save failed: #{reason}"
        end
      rescue => e
        if strict
          Tina4::Log.error("Seeder: row #{i} failed seeding #{orm_class.name} (strict): #{e.message}")
          raise
        end
        failed += 1
        errors << { row: i, message: e.message }
        Tina4::Log.warning("Seeder: row #{i} failed seeding #{orm_class.name}, skipped: #{e.message}")
      end
    end

    Tina4::Log.info("Seeder: #{orm_class.name} — seeded #{seeded}, #{failed} failed")
    SeedSummary.new(seeded: seeded, failed: failed, errors: errors)
  end

  # Seed a raw database table (no ORM class needed).
  #
  # Visible-but-resilient: each row is wrapped. On a row failure the cause is
  # logged (with the row index) and the row is skipped — unless +strict: true+,
  # in which case the FIRST failure RE-RAISES. A one-line summary is logged at
  # the end.
  #
  # @param table_name [String] name of the table
  # @param columns [Hash, Array] +{ column_name => type_string }+ OR an array of
  #   column descriptor hashes (+{ name:, type: }+) as returned by +db.columns+.
  #   Values may also be callables (or FakeData-receiving lambdas) — parity with
  #   the Python +field_map+.
  # @param count [Integer] number of records to insert
  # @param overrides [Hash] static values (or callables) set on every row
  # @param clear [Boolean] delete every existing row before seeding (P2)
  # @param seed [Integer, nil] random seed — seeds the FakeData RNG used for any
  #   generator that is not an explicit callable (P3 / signature parity)
  # @param strict [Boolean] re-raise on the first failed row instead of skipping (P1)
  # @return [SeedSummary] +{seeded, failed, errors}+ — also usable as the int count
  def self.seed_table(table_name, columns, count: 10, overrides: {}, clear: false, seed: nil, strict: false)
    fake = FakeData.new(seed: seed)
    db = Tina4.database

    unless db
      Tina4::Log.error("Seeder: No database connection.")
      return SeedSummary.new
    end

    field_map = _normalize_columns(columns)

    _clear_table(db, table_name) if clear

    seeded = 0
    failed = 0
    errors = []

    count.times do |i|
      begin
        row = {}
        field_map.each do |col_name, type_str|
          if overrides.key?(col_name)
            val = overrides[col_name]
            row[col_name] = val.respond_to?(:call) ? val.call(fake) : val
          elsif type_str.respond_to?(:call)
            # field_map value is itself a generator (Python field_map parity).
            row[col_name] = type_str.arity.zero? ? type_str.call : type_str.call(fake)
          else
            field_def = { type: type_str.to_sym }
            row[col_name] = fake.for_field(field_def, col_name)
          end
        end

        db.insert(table_name, row)
        seeded += 1
      rescue => e
        if strict
          Tina4::Log.error("Seeder: row #{i} failed seeding '#{table_name}' (strict): #{e.message}")
          raise
        end
        failed += 1
        errors << { row: i, message: e.message }
        Tina4::Log.warning("Seeder: row #{i} failed seeding '#{table_name}', skipped: #{e.message}")
      end
    end

    begin
      db.commit
    rescue StandardError
      # Autocommit-on engines / pooled standalone writes may not need an
      # explicit commit; never let the summary itself crash.
    end

    Tina4::Log.info("Seeder: '#{table_name}' — seeded #{seeded}, #{failed} failed")
    SeedSummary.new(seeded: seeded, failed: failed, errors: errors)
  end

  # Batch-seed several ORM models, ordering by their ForeignKeyField dependency
  # graph (P4a). Parent tables seed before children (topological sort over the
  # ORM's belongs_to/has_many FK metadata); when +clear: true+ the clear runs in
  # the REVERSE order so children are removed before parents — no FK violations
  # regardless of the order the caller lists the models in.
  #
  # @param orm_classes [Array<Class>] ORM subclasses to seed
  # @param count [Integer] rows per model
  # @param overrides [Hash] per-model overrides as +{ ModelClass => { field: value } }+
  #   or a single flat hash applied to every model
  # @param clear [Boolean] clear each table first (reverse-topo order)
  # @param seed [Integer, nil] PRNG seed (P3) — applied per model
  # @param strict [Boolean] re-raise on the first failed row
  # @return [Hash] +{ "ModelName" => SeedSummary }+ for each model seeded
  def self.seed_models(orm_classes, count: 10, overrides: {}, clear: false, seed: nil, strict: false)
    ordered = _topo_sort_models(orm_classes)

    if clear
      ordered.reverse_each { |model| _clear_orm(model) }
    end

    results = {}
    ordered.each do |model|
      model_overrides = overrides
      if overrides.is_a?(Hash) && overrides.key?(model)
        model_overrides = overrides[model]
      end
      results[model.name] = seed_orm(
        model, count: count, overrides: model_overrides || {},
        clear: false, seed: seed, strict: strict
      )
    end
    results
  end

  # Seed multiple ORM classes in batch with dependency-aware ordering.
  #
  # Backwards-compatible task form (+[{ orm_class:, count:, overrides:, seed: }]+).
  # The tasks are reordered by the FK dependency graph so parents seed before
  # children; +clear: true+ clears in reverse-topo order. Strict mode re-raises
  # on the first failed row of any task.
  #
  # @param tasks [Array<Hash>] each hash has :orm_class, :count, :overrides, :seed
  # @param clear [Boolean] delete existing records (reverse-topo order) before seeding
  # @param strict [Boolean] re-raise on the first failed row
  # @return [Hash] +{ "ClassName" => SeedSummary }+
  #
  # @example
  #   Tina4.seed_batch([
  #     { orm_class: User, count: 20 },
  #     { orm_class: Order, count: 100, overrides: { status: "pending" } }
  #   ], clear: true)
  def self.seed_batch(tasks, clear: false, strict: false)
    by_class = {}
    tasks.each { |t| by_class[t[:orm_class]] = t }
    ordered_classes = _topo_sort_models(tasks.map { |t| t[:orm_class] })

    if clear
      ordered_classes.reverse_each { |orm_class| _clear_orm(orm_class) }
    end

    results = {}
    ordered_classes.each do |orm_class|
      task = by_class[orm_class]
      results[orm_class.name] = seed_orm(
        orm_class,
        count: task[:count] || 10,
        overrides: task[:overrides] || {},
        clear: false,
        seed: task[:seed],
        strict: strict
      )
    end

    results
  end

  # --- internal helpers (P2/P4a/P4c) --------------------------------------

  # Normalise the +columns+ argument of +seed_table+ into a uniform
  # +{ column_name => type_or_callable }+ hash. Accepts a plain hash (the
  # documented form) OR an array of column-descriptor hashes
  # (+{ name:, type:, primary_key:, ... }+) as returned by +db.columns+,
  # skipping auto-increment / id primary keys so they are left to the engine.
  def self._normalize_columns(columns)
    return columns if columns.is_a?(Hash)

    map = {}
    Array(columns).each do |col|
      next unless col.is_a?(Hash)

      name = col[:name] || col["name"]
      next if name.nil?

      pk = col[:primary_key] || col["primary_key"]
      lname = name.to_s.downcase
      # Skip primary-key id columns — the engine assigns them.
      next if pk && lname == "id"

      type = col[:type] || col["type"] || "string"
      map[name.to_sym] = _normalize_sql_type(type)
    end
    map
  end

  # Map a raw SQL/driver type string to a FakeData field type symbol.
  def self._normalize_sql_type(type)
    t = type.to_s.downcase
    return :integer if t =~ /int|serial/
    return :float   if t =~ /real|float|double|numeric|decimal|money/
    return :boolean if t =~ /bool|bit/
    return :datetime if t =~ /datetime|timestamp/
    return :date     if t == "date"
    return :blob     if t =~ /blob|binary/
    return :text     if t =~ /text|clob/
    :string
  end

  # Delete every row in +table+. Tolerant — logs and continues on error.
  def self._clear_table(db, table)
    db.delete(table, "1=1")
    Tina4::Log.info("Seeder: Cleared #{table}")
  rescue => e
    Tina4::Log.warning("Seeder: could not clear '#{table}': #{e.message}")
  end

  # Delete every row backing an ORM model. Tolerant — logs and continues.
  def self._clear_orm(orm_class)
    db = orm_class.get_db
    return unless db

    db.delete(orm_class.table_name, "1=1")
    Tina4::Log.info("Seeder: Cleared #{orm_class.table_name}")
  rescue => e
    Tina4::Log.warning("Seeder: could not clear #{orm_class.name}: #{e.message}")
  end

  # For each foreign-key column on the model, fetch the existing primary-key
  # values of the referenced table so seeded child rows reference a real
  # parent (P4a). Returns +{ fk_column_sym => [pk_value, ...] }+; columns with
  # no resolvable / empty parent table are omitted (the generic generator then
  # fills them, and the row may fail loudly — never silently).
  def self._foreign_key_pools(orm_class, fields)
    pools = {}
    fk_columns = _foreign_keys_for(orm_class)
    fields.each_key do |name|
      ref_class = fk_columns[name.to_s]
      next unless ref_class

      begin
        db = ref_class.get_db
        next unless db

        pk = ref_class.primary_key_field || :id
        rows = db.fetch("SELECT #{pk} FROM #{ref_class.table_name}", [], limit: 100_000)
        list = rows.respond_to?(:to_a) ? rows.to_a : Array(rows)
        values = list.map { |r| r[pk] || r[pk.to_s] }.compact
        pools[name] = values unless values.empty?
      rescue => e
        Tina4::Log.warning("Seeder: could not resolve FK pool for #{name}: #{e.message}")
      end
    end
    pools
  end

  # Resolve the foreign-key columns declared on a model to their referenced
  # ORM classes. Reads the model's belongs_to relationship metadata (the
  # foreign_key_field DSL wires a belongs_to whose :foreign_key is the column
  # and :class_name names the parent). Returns +{ "column_name" => ParentClass }+.
  def self._foreign_keys_for(orm_class)
    out = {}
    return out unless orm_class.respond_to?(:relationship_definitions)

    orm_class.relationship_definitions.each_value do |rel|
      next unless rel[:type] == :belongs_to

      fk = (rel[:foreign_key] || "").to_s
      next if fk.empty?

      target = _resolve_model_by_name(rel[:class_name])
      out[fk] = target if target
    end
    out
  end

  # Topologically sort ORM models so parents (referenced tables) come before
  # children (tables with a FK pointing at them). Uses the belongs_to FK
  # metadata. Models not in the input list are ignored as dependencies.
  # Cycles / unresolved deps fall back to declared order so nothing is dropped.
  def self._topo_sort_models(orm_classes)
    in_set = orm_classes.uniq
    by_name = {}
    in_set.each { |m| by_name[m.name.to_s.split("::").last] = m }

    deps_of = {}
    in_set.each do |model|
      deps = []
      _foreign_keys_for(model).each_value do |ref_class|
        simple = ref_class.name.to_s.split("::").last
        target = by_name[simple]
        deps << target if target && !target.equal?(model)
      end
      deps_of[model] = deps.uniq
    end

    ordered = []
    placed = []
    remaining = in_set.dup
    progressed = true
    while !remaining.empty? && progressed
      progressed = false
      still = []
      remaining.each do |model|
        if deps_of[model].all? { |d| placed.include?(d) }
          ordered << model
          placed << model
          progressed = true
        else
          still << model
        end
      end
      remaining = still
    end
    # Cycle / unresolved deps — append in declared order so we never drop a model.
    ordered.concat(remaining)
    ordered
  end

  # Find a loaded Tina4::ORM subclass by its simple (unqualified) class name.
  def self._resolve_model_by_name(class_name)
    return nil if class_name.nil?
    return class_name if class_name.is_a?(Class)

    simple = class_name.to_s.split("::").last
    return nil unless defined?(Tina4::ORM) && Tina4::ORM.respond_to?(:model_subclasses)

    Tina4::ORM.model_subclasses.find do |k|
      k.name && k.name.split("::").last == simple
    end
  end

  # P4c — when a generated/static value's Ruby type clearly mismatches the
  # target column's field type, LOG a warning (never hard-fail). bool-in-int
  # is allowed (Ruby has no bool/int subclass relation, but seeded booleans are
  # represented as 0/1 integers here, so only flag truly suspicious cases).
  def self._validate_types(fields, attrs, model_name)
    expected = { integer: Integer, float: Float, boolean: Integer }
    attrs.each do |name, value|
      next if value.nil?

      field = fields[name]
      next if field.nil?

      want = expected[field[:type]]
      next if want.nil?

      # A Float landing in an :integer column (or vice-versa) is the suspicious
      # case; everything that is_a? the expected numeric is fine.
      next if value.is_a?(want)
      next if want == Integer && value.is_a?(Numeric) && field[:type] == :boolean

      Tina4::Log.warning(
        "Seeder: #{model_name}.#{name} expected #{want} but generated " \
        "#{value.class} (#{value.inspect}) — inserting anyway"
      )
    end
  end

  # Run all seed files in the given folder.
  #
  # Parity: Python/PHP/Node use `seed(n)` to set the PRNG seed on FakeData.
  # Ruby's FakeData.seed already does that — this folder-runner is named
  # differently to avoid the collision.
  #
  # @param seed_folder [String] path to seed files (default: "seeds")
  def self.run_seeds(seed_folder: "seeds", clear: false)
    seed_dir(seed_folder: seed_folder, clear: clear)
  end

  # Run all seed files in the given folder.
  #
  # @param seed_folder [String] path to seed files (default: "seeds")
  def self.seed_dir(seed_folder: "seeds", clear: false)
    unless Dir.exist?(seed_folder)
      Tina4::Log.info("Seeder: No seeds folder found at #{seed_folder}")
      return
    end

    files = Dir.glob(File.join(seed_folder, "*.rb")).sort
    files.reject! { |f| File.basename(f).start_with?("_") }

    if files.empty?
      Tina4::Log.info("Seeder: No seed files found in #{seed_folder}")
      return
    end

    Tina4::Log.info("Seeder: Found #{files.length} seed file(s) in #{seed_folder}")

    files.each do |filepath|
      begin
        Tina4::Log.info("Seeder: Running #{File.basename(filepath)}...")
        load filepath
        Tina4::Log.info("Seeder: Completed #{File.basename(filepath)}")
      rescue => e
        Tina4::Log.error("Seeder: Failed to run #{File.basename(filepath)}: #{e.message}")
      end
    end
  end
end
