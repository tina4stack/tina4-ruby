# frozen_string_literal: true

# The canonical test-environment variable contract (ADR-0038).
#
# spec/fixtures/test_env_contract.json is byte-identical in all four frameworks
# and IS the source of truth for which test-environment variables exist. This
# spec is the Ruby gate: it scans this framework's own suite plus
# .github/workflows and FAILS, naming the offender and its file, on any name
# that is not on the list.
#
# WHY. One test PostgreSQL had thirteen names and no two frameworks read the
# same set - _USER and _USERNAME, _PASS and _PASSWORD, _DB and _DATABASE, PG_URL
# and POSTGRES_URL all meant the same thing. Twice in one night a test skipped,
# someone exported the single name that one framework happened to read, and more
# tests appeared. Both fixes were correct and neither could have been the last,
# because there was no canonical list to check against. Adding a fourteenth
# spelling now turns this suite RED instead of silently turning a test off.
#
# Workflows are scanned as well as specs, deliberately: a CI file that SETS a
# name no spec READS is the exact failure that hid 4 Node tests and 3 PHP sites.
#
# NO MOCKS, and none are possible - this reads the real fixture and the real
# files in the real repository. The negative case runs the SAME checker over a
# synthetic source string, so a checker that reported nothing would fail it.

require "spec_helper"
require "json"

RSpec.describe "test-env variable contract" do
  # Locals, not constants. A constant assigned inside an RSpec.describe block is
  # defined on Object, i.e. GLOBAL, and clobbers every other spec file that uses
  # the same name - see the comment in queue_delay_invariant_spec.rb for what
  # that cost us (a spec spawned its Puma on 27017 and spoke HTTP to MongoDB).
  repo_root    = File.expand_path("..", __dir__)
  fixture_path = File.join(__dir__, "fixtures", "test_env_contract.json")
  contract     = JSON.parse(File.read(fixture_path))

  # This spec sits under spec/, so the scan below reads THIS FILE TOO. One
  # literal occurrence of the variable prefix here - in the regexp source, in a
  # comment, in the describe name - would be reported as a violation of itself.
  # Assembling the prefix from two pieces keeps the source clean, and the
  # pattern, the canonical names and the negative case all derive from it.
  # rubocop:disable Style/StringConcatenation
  # DO NOT let an autocorrect fold this into one literal. The split is the whole
  # point: a single "TINA4_TEST_" literal here would be a name this file is
  # reading, the scan below would find it in its own source, and the gate would
  # fail against itself.
  prefix = "TINA4" + "_TEST_"
  # rubocop:enable Style/StringConcatenation

  # A name counts only where it is USED, not where it is DISCUSSED. Matching the
  # bare token anywhere flagged ordinary prose - a comment naming the MYSQL_ or
  # MSSQL_ family, or a wildcard in a workflow header - as if it were a read.
  # A use is one of:
  #   ['"]            a string literal: ENV["X"], ENV.fetch('X'), echo "X=..."
  #   process.env.    not reachable from Ruby; kept so all four gates share one rule
  #   export          a shell export, ANYWHERE on the line - not just at its start
  #   line start      a YAML env key (  X: value)
  # The trailing + (not *) means the bare prefix alone never matches. Ruby's ^ is
  # already start-of-line, so no flag is needed.
  #
  # `export` is deliberately NOT anchored to the line start. spec/support/
  # mqtt-infra.sh emits `echo "export TINA4_...MQTT_URL=..."` - the export sits
  # mid-line after `echo "`, so an anchored form matched NONE of those five
  # names. They were being SET and never checked, which is the precise failure
  # this gate exists to catch. Verified: anchored saw 0 of 5, unanchored sees 5.
  # This matches the Python reference implementation exactly.
  token_pattern = Regexp.new("(?:['\"]|process\\.env\\.|export\\s+|^\\s*)(#{prefix}[A-Z0-9_]+)")

  # scan with one capture group yields [[name], [name], ...]
  scan_names = ->(source) { source.scan(token_pattern).flatten }

  # THE CANONICAL SET: every <SERVICE>_<ATTRIBUTE> pair the fixture declares,
  # plus the test-owned fixture variables that carry no service grammar.
  canonical = contract["services"].flat_map do |service, attributes|
    attributes.map { |attribute| "#{prefix}#{service}_#{attribute}" }
  end
  canonical += contract["fixtures"]
  canonical.freeze

  # Literal prefixes of names BUILT at runtime, which no static scan can
  # resolve. Allowed only as an exact match, never as a wildcard.
  dynamic_prefixes = contract["dynamic_prefixes"]

  # THE CHECKER. The repository scan and the negative case both call this one
  # lambda, so a checker that found nothing would fail the negative case.
  find_violations = lambda do |source|
    scan_names.call(source).uniq.reject do |name|
      canonical.include?(name) || dynamic_prefixes.include?(name)
    end
  end

  # Every file under the Ruby scan paths, MINUS the fixture itself: it is the
  # definition, and its prose deliberately names the retired spellings.
  scanned_files = contract["scan_paths"]["ruby"].flat_map do |relative_path|
    Dir.glob(File.join(repo_root, relative_path, "**", "*"), File::FNM_DOTMATCH)
  end
  scanned_files = scanned_files
                  .select { |path| File.file?(path) }
                  .reject { |path| File.expand_path(path) == File.expand_path(fixture_path) }
                  .sort

  # binread + scrub: spec/ carries binary fixtures, and a BINARY-encoded string
  # cannot be scanned with a UTF-8 regexp (Encoding::CompatibilityError).
  read_text = ->(path) { File.binread(path).force_encoding("UTF-8").scrub("") }

  relative = ->(path) { path.sub("#{repo_root}/", "") }

  it "every test-env variable in the suite and in CI is on the canonical list" do
    offenders = Hash.new { |hash, key| hash[key] = [] }

    scanned_files.each do |path|
      find_violations.call(read_text.call(path)).each do |name|
        offenders[name] << relative.call(path)
      end
    end

    detail = offenders.map { |name, files| "  #{name}\n      #{files.join("\n      ")}" }.join("\n")

    expect(offenders).to be_empty, <<~MESSAGE
      #{offenders.size} test-env variable name(s) are not on the canonical list:

      #{detail}

      The canonical list is spec/fixtures/test_env_contract.json (ADR-0038),
      byte-identical in all four frameworks. Either use the canonical spelling,
      or add the name to that fixture FIRST - in every framework - and then use
      it. A name that is not in the fixture does not exist.
    MESSAGE
  end

  # A broken glob, a wrong repo root, or an unreadable file would find NO tokens
  # and the example above would pass green while checking nothing. These
  # assertions are the proof that the scan actually read the suite.
  it "the scan reads the real suite (guards against a vacuous pass)" do
    all_tokens = scanned_files.flat_map { |path| scan_names.call(read_text.call(path)) }

    expect(scanned_files.size).to be >= 20,
                                  "only #{scanned_files.size} files scanned - the glob is broken"
    expect(all_tokens.size).to be >= 40,
                               "only #{all_tokens.size} test-env tokens found - the scan is not reading the suite"
    # Two names this suite really reads, in bulk (12 uses each). NOT PG_URL: the
    # Ruby suite builds its PostgreSQL connection from the discrete HOST / PORT /
    # USERNAME / PASSWORD / DB parts and never reads PG_URL, which survives here
    # only in two historical comments. Asserting on it would pin a name nothing
    # uses - and prose does not count as a read.
    expect(all_tokens).to include("#{prefix}PG_HOST")
    expect(all_tokens).to include("#{prefix}PG_USERNAME")

    # The de-interpolated queue specs (STEP 2b). These names were invisible to
    # any static scan until they were spelled out, so assert the gate SEES them
    # - otherwise de-interpolating them bought nothing.
    expect(all_tokens).to include("#{prefix}RABBITMQ_HOST")
    expect(all_tokens).to include("#{prefix}KAFKA_PORT")
  end

  # NEGATIVE: the checker must actually REPORT a name that is off the list. The
  # bogus name is assembled at runtime so the literal never appears in this file
  # and cannot trip the real scan above.
  it "reports a name that is not on the canonical list" do
    bogus = "#{prefix}PG_FOO"
    source = %(host = ENV["#{bogus}"] || "127.0.0.1"\nport = ENV["#{prefix}PG_PORT"].to_i\n)

    violations = find_violations.call(source)

    expect(violations).to eq([bogus]),
                          "the checker must report #{bogus} and must NOT report the canonical PG_PORT"
  end

  # FORM COVERAGE. One case per way a name can be written at a real use site,
  # every one setting or reading the SAME off-list name. A form the pattern
  # cannot see is a name that can be set or read without the gate noticing - the
  # echoed-export form below was exactly that, and matched nothing until the
  # `export` alternative was un-anchored from the line start.
  it "catches an off-list name written in every form a use site uses" do
    bogus = "#{prefix}PG_FOO"

    {
      "quoted read" => %(ENV['#{bogus}']),
      "double-quoted read" => %(ENV["#{bogus}"]),
      "node dot form" => "process.env.#{bogus}",
      "yaml env key" => "      #{bogus}: postgres://host/db",
      "line-start export" => "export #{bogus}=x",
      "echoed export" => %(echo "export #{bogus}=x"),
      "echoed assignment" => %(echo "#{bogus}=$X" >> "$GITHUB_ENV")
    }.each do |form, source|
      expect(find_violations.call(source)).to eq([bogus]),
                                              "the #{form} form is invisible to the gate: #{source.inspect}"
    end
  end

  # NEGATIVE: a declared dynamic prefix is allowed as an EXACT match only. An
  # undeclared name that merely looks like one is still a violation.
  it "allows a declared dynamic prefix but not an undeclared look-alike" do
    declared = dynamic_prefixes.first
    look_alike = "#{prefix}DB_MISSING_"

    expect(find_violations.call(%(getenv("#{declared}" . uniqid())))).to eq([])
    expect(find_violations.call(%(getenv("#{look_alike}" . uniqid())))).to eq([look_alike])
  end
end
