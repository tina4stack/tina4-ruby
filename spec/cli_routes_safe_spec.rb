# frozen_string_literal: true

require "spec_helper"
require "open3"
require "json"

RSpec.describe "tina4ruby routes safe discovery" do
  it "lists source routes without executing app.rb" do
    Dir.mktmpdir("tina4-routes-safe") do |project|
      fixture = JSON.parse(File.read(File.join(__dir__, "fixtures", "cli_routes_contract.json")))
      invariants = fixture.fetch("invariants").to_h { |item| [item.fetch("id"), item] }
      route_path = invariants.fetch("canonical-route-is-listed").fetch("route_path")
      marker_name = invariants.fetch("application-entrypoint-is-not-executed").fetch("marker_name")
      routes = File.join(project, "src", "routes")
      FileUtils.mkdir_p(routes)
      File.write(
        File.join(routes, "probe.rb"),
        "Tina4::Router.get(#{route_path.inspect}) { |_request, response| response.call({ ok: true }) }\n"
      )
      marker = File.join(project, marker_name)
      File.write(
        File.join(project, "app.rb"),
        "File.write(#{marker.inspect}, 'unsafe')\nraise 'routes executed app.rb'\n"
      )

      cli = File.expand_path("../exe/tina4ruby", __dir__)
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, cli, "routes", chdir: project)

      expect(status.exitstatus).to eq(0), stdout + stderr
      expect(stdout).to include(route_path)
      expect(File).not_to exist(marker)
    end
  end
end
