# frozen_string_literal: true

require "spec_helper"

RSpec.describe Tina4::Debug do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe ".setup" do
    it "creates the logs directory" do
      Tina4::Debug.setup(tmpdir)
      expect(Dir.exist?(File.join(tmpdir, "logs"))).to be true
    end

    it "creates debug.log file" do
      Tina4::Debug.setup(tmpdir)
      Tina4::Debug.info("test message")
      expect(File.exist?(File.join(tmpdir, "logs", "debug.log"))).to be true
    end
  end

  describe "logging methods" do
    before { Tina4::Debug.setup(tmpdir) }

    it "responds to .info" do
      expect(Tina4::Debug).to respond_to(:info)
    end

    it "responds to .debug" do
      expect(Tina4::Debug).to respond_to(:debug)
    end

    it "responds to .warning" do
      expect(Tina4::Debug).to respond_to(:warning)
    end

    it "responds to .error" do
      expect(Tina4::Debug).to respond_to(:error)
    end

    it "does not raise when logging" do
      expect { Tina4::Debug.info("test") }.not_to raise_error
      expect { Tina4::Debug.debug("test") }.not_to raise_error
      expect { Tina4::Debug.warning("test") }.not_to raise_error
      expect { Tina4::Debug.error("test") }.not_to raise_error
    end
  end
end
