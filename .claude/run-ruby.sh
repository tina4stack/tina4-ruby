#!/bin/bash
export PATH="/opt/homebrew/opt/ruby/bin:$PATH"
export GEM_HOME="$(/opt/homebrew/opt/ruby/bin/ruby -e 'puts Gem.user_dir')"
export GEM_PATH="$GEM_HOME:$(/opt/homebrew/opt/ruby/bin/ruby -e 'puts Gem.dir')"
cd /Users/andrevanzuydam/IdeaProjects/tina4-ruby
exec /opt/homebrew/opt/ruby/bin/bundle "$@"
