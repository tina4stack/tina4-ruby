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

  # Seed an ORM class with auto-generated fake data.
  #
  # @param orm_class [Class] ORM subclass (e.g., User, Product)
  # @param count [Integer] number of records to insert
  # @param overrides [Hash] field overrides — static values or lambdas receiving FakeData
  # @param clear [Boolean] delete existing records before seeding
  # @param seed [Integer, nil] random seed for reproducible data
  # @return [Integer] number of records inserted
  #
  # @example
  #   Tina4.seed_orm(User, count: 50)
  #   Tina4.seed_orm(Order, count: 200, overrides: { status: ->(f) { f.choice(%w[pending shipped]) } })
  def self.seed_orm(orm_class, count: 10, overrides: {}, clear: false, seed: nil)
    fake = FakeData.new(seed: seed)
    fields = orm_class.field_definitions
    table = orm_class.table_name

    if fields.empty?
      Tina4::Log.error("Seeder: No fields found on #{orm_class.name}")
      return 0
    end

    db = Tina4.database
    unless db
      Tina4::Log.error("Seeder: No database connection. Set Tina4.database first.")
      return 0
    end

    # Idempotency check
    unless clear
      begin
        result = db.fetch_one("SELECT count(*) as cnt FROM #{table}")
        if result && result[:cnt].to_i >= count
          Tina4::Log.info("Seeder: #{table} already has #{result[:cnt]} records, skipping")
          return 0
        end
      rescue => e
        # Table might not exist
      end
    end

    # Clear if requested
    if clear
      begin
        db.execute("DELETE FROM #{table}")
        Tina4::Log.info("Seeder: Cleared #{table}")
      rescue => e
        Tina4::Log.warn("Seeder: Could not clear #{table}: #{e.message}")
      end
    end

    # Identify fields to populate
    pk_field = orm_class.primary_key_field
    insert_fields = fields.reject { |name, opts| opts[:primary_key] && opts[:auto_increment] }

    inserted = 0
    count.times do |i|
      attrs = {}

      insert_fields.each do |name, field_def|
        if overrides.key?(name)
          val = overrides[name]
          attrs[name] = val.respond_to?(:call) ? val.call(fake) : val
        else
          generated = fake.for_field(field_def, name)
          attrs[name] = generated unless generated.nil?
        end
      end

      begin
        obj = orm_class.new(attrs)
        if obj.save
          inserted += 1
        else
          Tina4::Log.warn("Seeder: Insert failed for #{table} row #{i + 1}: #{obj.errors.join(', ')}")
        end
      rescue => e
        Tina4::Log.warn("Seeder: Insert failed for #{table} row #{i + 1}: #{e.message}")
      end
    end

    Tina4::Log.info("Seeder: Inserted #{inserted}/#{count} records into #{table}")
    inserted
  end

  # Seed a raw database table (no ORM class needed).
  #
  # @param table_name [String] name of the table
  # @param columns [Hash] { column_name: type_string } — supports :integer, :string, :text, etc.
  # @param count [Integer] number of records to insert
  # @param overrides [Hash] field overrides
  # @param clear [Boolean] delete before seeding
  # @param seed [Integer, nil] random seed
  # @return [Integer] records inserted
  def self.seed_table(table_name, columns, count: 10, overrides: {}, clear: false, seed: nil)
    fake = FakeData.new(seed: seed)
    db = Tina4.database

    unless db
      Tina4::Log.error("Seeder: No database connection.")
      return 0
    end

    if clear
      begin
        db.execute("DELETE FROM #{table_name}")
      rescue => e
        Tina4::Log.warn("Seeder: Could not clear #{table_name}: #{e.message}")
      end
    end

    inserted = 0
    count.times do |i|
      row = {}
      columns.each do |col_name, type_str|
        if overrides.key?(col_name)
          val = overrides[col_name]
          row[col_name] = val.respond_to?(:call) ? val.call(fake) : val
        else
          field_def = { type: type_str.to_sym }
          row[col_name] = fake.for_field(field_def, col_name)
        end
      end

      begin
        db.insert(table_name, row)
        inserted += 1
      rescue => e
        Tina4::Log.warn("Seeder: Insert failed for #{table_name} row #{i + 1}: #{e.message}")
      end
    end

    Tina4::Log.info("Seeder: Inserted #{inserted}/#{count} records into #{table_name}")
    inserted
  end

  # Seed multiple ORM classes in batch with optional dependency-aware clearing.
  #
  # @param tasks [Array<Hash>] each hash has :orm_class, :count, :overrides, :seed
  # @param clear [Boolean] delete existing records (in reverse order) before seeding
  # @return [Hash] { "ClassName" => inserted_count, ... }
  #
  # @example
  #   Tina4.seed_batch([
  #     { orm_class: User, count: 20 },
  #     { orm_class: Order, count: 100, overrides: { status: "pending" } }
  #   ], clear: true)
  def self.seed_batch(tasks, clear: false)
    results = {}

    if clear
      tasks.reverse_each do |task|
        begin
          Tina4.database&.execute("DELETE FROM #{task[:orm_class].table_name}")
          Tina4::Log.info("Seeder: Cleared #{task[:orm_class].table_name}")
        rescue => e
          Tina4::Log.warn("Seeder: Could not clear #{task[:orm_class].table_name}: #{e.message}")
        end
      end
    end

    tasks.each do |task|
      n = Tina4.seed_orm(
        task[:orm_class],
        count: task[:count] || 10,
        overrides: task[:overrides] || {},
        clear: false,
        seed: task[:seed]
      )
      results[task[:orm_class].name] = n
    end

    results
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
