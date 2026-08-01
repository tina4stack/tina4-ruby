# frozen_string_literal: true

# ── Real environment variables — the no-mock replacement for ENV doubles ──────
#
# `allow(ENV).to receive(:[]).with("TINA4_DEBUG").and_return("true")` is a
# partial double on ENV, a real collaborator. It intercepts ENV#[] and NOTHING
# ELSE: production code reading the same variable through ENV.fetch, ENV.key?,
# ENV.to_h, or a value memoised at require time sees the UNSTUBBED environment.
# So a gate can test green while the real gate is wide open — which is how a
# debug/MCP endpoint stays exposed in production with a passing suite.
#
# set_real_env sets the REAL variable in the REAL process environment, so every
# read path sees it, and restores the previous value (including "was unset")
# after the example. env_vars_spec.rb:19-37 already ships the block-scoped
# `with_env`; this is the same contract in a before/it-friendly form for specs
# whose setup and assertion are not in one block.
module RealEnv
  UNSET = :__tina4_unset__

  # Set one or more REAL env vars for the rest of the example. nil deletes.
  #
  #   set_real_env("TINA4_DEBUG" => "true", "TINA4_MCP_TOKEN" => nil)
  #
  # The first value saved for a key wins, so repeated calls in one example still
  # restore the ORIGINAL value, not an intermediate one.
  def set_real_env(vars)
    @__real_env_saved ||= {}
    vars.each do |key, value|
      k = key.to_s
      @__real_env_saved[k] = ENV.key?(k) ? ENV[k] : UNSET unless @__real_env_saved.key?(k)
      value.nil? ? ENV.delete(k) : ENV[k] = value.to_s
    end
  end

  # Restore every variable set_real_env touched. Wired into a global after(:each)
  # below, so specs never have to remember it.
  def restore_real_env
    return unless defined?(@__real_env_saved) && @__real_env_saved

    @__real_env_saved.each do |k, v|
      v == UNSET ? ENV.delete(k) : ENV[k] = v
    end
    @__real_env_saved = nil
  end
end

RSpec.configure do |config|
  config.include RealEnv
  config.after(:each) { restore_real_env }
end
