# frozen_string_literal: true

# Feature 53 - Frond {% include %} / {% extends %} path confinement (TAG-DEC-01).
#
# Real templates on disk, a real secret file OUTSIDE the templates dir, and a
# real symlink -- NO mocks. Every case drives the REAL Frond engine against files
# it wrote to a temp directory. A legit include/extends UNDER the templates dir
# renders; a `..` traversal, an absolute path, and a symlink whose realpath
# escapes the templates dir are all REFUSED (a clear error, never the outside
# file's bytes).
#
# Mutation proof: drop the containment guard in Tina4::Frond#load_template
# (lib/tina4/frond.rb) and the traversal / absolute / symlink cases RENDER the
# outside file's SECRET marker instead of raising -- these examples then go RED.
#
# Shared conformance fixture:
# tina4-documentation/plan/v3/fixtures/frondtags_contract.json

require_relative "spec_helper"
require_relative "../lib/tina4/frond"
require "tmpdir"
require "fileutils"

RSpec.describe "Tina4::Frond include/extends path confinement (TAG-DEC-01)" do
  # A REAL templates dir with a legit partial + base, and a REAL secret file
  # OUTSIDE it, freshly built per example and removed afterwards. The marker is
  # an ivar (not a bare constant, which would be global across every spec file).
  around(:each) do |example|
    Dir.mktmpdir("frondtags_rb_") do |base|
      @secret_marker = "TOP-SECRET-OUTSIDE-9f83c1"
      @templates = File.join(base, "templates")
      FileUtils.mkdir_p(File.join(@templates, "partials"))
      File.write(File.join(@templates, "partials", "hello.twig"), "Hello from a real partial")
      File.write(File.join(@templates, "base.twig"), "[BASE {% block body %}default{% endblock %} END]")
      @secret_path = File.join(base, "secret.txt") # lives OUTSIDE templates/
      File.write(@secret_path, @secret_marker)
      example.run
    end
  end

  # Render must RAISE (refused) and the SECRET must never leak into the message.
  def expect_refused(template)
    expect { Tina4::Frond.new(template_dir: @templates).render(template) }
      .to raise_error(RuntimeError) do |error|
        expect(error.message).to match(/escape/)
        expect(error.message).not_to include(@secret_marker)
      end
  end

  it "a legit include renders under the templates dir" do
    File.write(File.join(@templates, "page.twig"), 'X {% include "partials/hello.twig" %} Y')
    out = Tina4::Frond.new(template_dir: @templates).render("page.twig")
    expect(out).to include("Hello from a real partial")
  end

  it "a legit extends renders under the templates dir" do
    File.write(File.join(@templates, "child.twig"),
               '{% extends "base.twig" %}{% block body %}CHILD-BODY{% endblock %}')
    out = Tina4::Frond.new(template_dir: @templates).render("child.twig")
    expect(out).to include("CHILD-BODY")
    expect(out).to include("BASE") # the parent shell rendered too
  end

  it "a dot dot traversal include is refused" do
    # ../secret.txt climbs OUT of the templates dir.
    File.write(File.join(@templates, "evil.twig"), '{% include "../secret.txt" %}')
    expect_refused("evil.twig")
  end

  it "an absolute path include is refused" do
    # An absolute path to the real secret file.
    File.write(File.join(@templates, "evil_abs.twig"), %({% include "#{@secret_path}" %}))
    expect_refused("evil_abs.twig")
  end

  it "a symlink escaping the templates dir is refused" do
    # A REAL symlink INSIDE the templates dir whose target is the secret OUTSIDE
    # it. Its name has no `..` and is not absolute, so only the realpath
    # containment can catch it.
    File.symlink(@secret_path, File.join(@templates, "sneaky.twig"))
    File.write(File.join(@templates, "evil_link.twig"), '{% include "sneaky.twig" %}')
    expect_refused("evil_link.twig")
  end
end
