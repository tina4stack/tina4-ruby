# frozen_string_literal: true

# ── A genuinely FULL filesystem — no simulated write failures ─────────────────
#
# Replaces `allow(@file_logger).to receive(:<<).and_raise(IOError.new("disk
# full"))`. That stub proved Tina4::Log re-raises when something raises IOError
# from #<<; it could not prove anything about a real disk-full condition,
# because it bypassed the entire real write path.
#
# This mounts a REAL, tiny, disposable filesystem, fills it for real, and lets
# the real OS raise Errno::ENOSPC. Everything is torn down in an ensure block.
#
# Skips LOUDLY (naming the mechanism) when a ram disk cannot be created, rather
# than silently degrading to a stub.
module RealFullDisk
  # Yields a path on a REAL filesystem that has just enough room for the block's
  # setup, then can be filled to a genuine ENOSPC via the passed filler lambda.
  #
  #   with_real_tiny_filesystem do |dir, fill_it|
  #     Tina4::Log.configure(dir)   # opens the real log while space remains
  #     fill_it.call               # real ENOSPC territory from here on
  #     Tina4::Log.info("boom")
  #   end
  def with_real_tiny_filesystem(volume_name: "TINA4RAMTEST", blocks: 2048)
    unless RUBY_PLATFORM.include?("darwin")
      skip "real full-filesystem test needs a disposable ram disk; " \
           "only the macOS hdiutil path is implemented (this is #{RUBY_PLATFORM}). " \
           "On Linux CI mount a size-capped tmpfs and pass its path instead."
    end

    dev = `hdiutil attach -nomount ram://#{blocks} 2>/dev/null`.strip
    if dev.empty?
      skip "could not attach a ram disk via `hdiutil attach -nomount ram://#{blocks}` — " \
           "cannot produce a real ENOSPC, and simulating one is not permitted"
    end

    mount_point = "/Volumes/#{volume_name}"
    erase = `diskutil eraseVolume HFS+ #{volume_name} #{dev} 2>&1`
    unless File.directory?(mount_point)
      `hdiutil detach #{dev} -force >/dev/null 2>&1`
      skip "could not format/mount the ram disk at #{mount_point}: #{erase.lines.last.to_s.strip}"
    end

    # Fills the REAL filesystem until the REAL kernel refuses another byte.
    filler = lambda do
      path = File.join(mount_point, "filler.bin")
      begin
        File.open(path, "wb") do |f|
          10_000.times { f.write("x" * 8192); f.flush }
        end
      rescue Errno::ENOSPC, Errno::EDQUOT, IOError
        # Expected: the filesystem is now genuinely full.
      end
    end

    yield mount_point, filler
  ensure
    if dev && !dev.empty?
      `diskutil unmount force #{dev} >/dev/null 2>&1`
      `hdiutil detach #{dev} -force >/dev/null 2>&1`
    end
  end
end

RSpec.configure do |config|
  config.include RealFullDisk
end
