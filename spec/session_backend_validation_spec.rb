# frozen_string_literal: true

require "spec_helper"

# Tests for TINA4_SESSION_BACKEND name validation.
#
# An unrecognised session backend name must RAISE, not silently become `file`.
#
# The bug these lock in: Session#create_handler ended in a bare
# `else FileHandler.new(...)`, and the comment above it described that silent
# fallback as correct parity with Python. It was parity, and both were wrong. A
# typo in TINA4_SESSION_BACKEND ("redsi") produced a running app writing sessions
# to local disk while the operator believed they were in Redis: nothing logged,
# nothing failed, and the symptom surfaced much later as users being logged out
# whenever a request landed on another instance.
#
# NO MOCKS and no dependency: every case here is the pure name -> outcome
# decision, asserted through the real Session. Nothing is stubbed, and the cases
# that would need a live backend deliberately assert only that the name is not
# REJECTED, rather than opening a connection.
#
# Identical case names in all four frameworks:
#   tina4-python/tests/test_session_backend_validation.py
#   tina4-php/tests/SessionBackendValidationTest.php
#   tina4-nodejs/test/sessionBackendValidation.test.ts
RSpec.describe "Session backend validation" do
  around do |example|
    previous = ENV.fetch("TINA4_SESSION_BACKEND", nil)
    ENV.delete("TINA4_SESSION_BACKEND")
    example.run
  ensure
    ENV.delete("TINA4_SESSION_BACKEND")
    ENV["TINA4_SESSION_BACKEND"] = previous if previous
  end

  # NEGATIVE: the actual bug. This returned a FileHandler before.
  it "an unknown session backend raises instead of silently using file" do
    ENV["TINA4_SESSION_BACKEND"] = "redsi"

    expect { Tina4::Session.new({}) }
      .to raise_error(ArgumentError, /Unknown session backend/)
  end

  it "the error names the unknown backend and the valid ones" do
    ENV["TINA4_SESSION_BACKEND"] = "postgres"

    expect { Tina4::Session.new({}) }.to raise_error(ArgumentError) do |error|
      expect(error.message).to include("postgres"),
                               "the operator cannot see which value was wrong"
      Tina4::Session::CANONICAL_BACKENDS.each do |canonical|
        expect(error.message).to include(canonical),
                                 "the message does not offer #{canonical}"
      end
    end
  end

  # POSITIVE: the documented default must survive the new strictness.
  it "an unset backend still defaults to file" do
    expect { Tina4::Session.new({}) }.not_to raise_error
  end

  # POSITIVE, and the subtle one. An env var set to "" is a SET variable.
  # Treating blank as an unknown name would break every deployment that clears
  # the var to take the default.
  it "a blank backend still defaults to file" do
    ["", "   "].each do |blank|
      ENV["TINA4_SESSION_BACKEND"] = blank
      expect { Tina4::Session.new({}) }.not_to raise_error
    end
  end

  # A .env line easily carries a trailing space or a capital.
  it "a backend name is case and whitespace insensitive" do
    ["FILE", " file ", "FileSystem", "\tfilesystem\n"].each do |spelling|
      ENV["TINA4_SESSION_BACKEND"] = spelling
      expect { Tina4::Session.new({}) }.not_to raise_error, "rejected: #{spelling.inspect}"
    end
  end

  # POSITIVE: the new rejection must not swallow a name that IS valid.
  #
  # Only the NAME decision is asserted. Building the redis/mongo/database handler
  # reaches for a real service, and this case is about validation, so a backend
  # that fails to CONNECT still counts as accepted - what must never happen is
  # the "Unknown session backend" rejection.
  it "every documented backend name is accepted" do
    Tina4::Session::VALID_BACKENDS.each do |name|
      ENV["TINA4_SESSION_BACKEND"] = name
      begin
        Tina4::Session.new({})
      rescue ArgumentError => e
        expect(e.message).not_to include("Unknown session backend"),
                                 "#{name} is in VALID_BACKENDS but the dispatch rejected it"
      rescue StandardError
        # a connection/driver failure is not a NAME failure
      end
    end
  end

  # The error message offers CANONICAL_BACKENDS. If one of those were not itself
  # accepted, the message would be telling operators to set an invalid value.
  it "the canonical names are all themselves valid" do
    Tina4::Session::CANONICAL_BACKENDS.each do |canonical|
      expect(Tina4::Session::VALID_BACKENDS).to include(canonical)
    end
  end
end
