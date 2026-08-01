# frozen_string_literal: true

require "tmpdir"
require "spec_helper"

# Regression: Response#file must not serve a file outside its root.
#
# The bug: the natural spelling of a download route,
#
#     response.file("downloads/" + name)   # name = "../secret.env"
#
# served any file the process could read.
#
# Two properties are pinned, and BOTH matter:
#
#   - the single-hop escape "downloads/../secret.env" is refused. This is the
#     discriminating case. A deep "../../../.." chain can climb above / and
#     resolve to nothing, so it can 404 on a VULNERABLE build too - a spec
#     that only checks the deep chain passes against the bug.
#   - a legitimate file inside the root is still served. Without this negative
#     control, a "fix" that simply breaks file() would pass.
#
# No mocks: real files on a real temp filesystem.
RSpec.describe "Tina4::Response#file path confinement" do
  around do |example|
    Dir.mktmpdir("tina4-trav") do |dir|
      @root = File.realpath(dir)
      Dir.mkdir(File.join(@root, "downloads"))
      File.write(File.join(@root, "downloads", "report.txt"), "PUBLIC REPORT\n")
      File.write(File.join(@root, "secret.env"), "TINA4_SECRET=super-secret-value\n")
      Dir.chdir(@root) { example.run }
    end
  end

  def serve(path, root: nil)
    response = Tina4::Response.new
    response.file(path, root: root)
    response
  end

  it "serves a file inside the root (NEGATIVE CONTROL)" do
    response = serve("downloads/report.txt")
    expect(response.status_code).to eq(200)
    expect(response.body).to eq("PUBLIC REPORT\n")
  end

  it "refuses a single-hop escape to a real file next door" do
    response = serve("downloads/../secret.env")
    expect(response.status_code).to eq(403)
    expect(response.body.to_s).not_to include("super-secret-value")
  end

  it "refuses a deep traversal chain" do
    expect(serve("../../../../../../etc/passwd").status_code).to eq(403)
  end

  it "refuses an absolute path outside the root (no '..' at all)" do
    expect(serve("/etc/passwd").status_code).to eq(403)
  end

  it "honours an explicit root instead of the working directory" do
    downloads = File.join(@root, "downloads")
    Dir.chdir(downloads) do
      expect(serve("report.txt", root: downloads).status_code).to eq(200)
      expect(serve("../secret.env", root: downloads).status_code).to eq(403)
    end
  end
end
