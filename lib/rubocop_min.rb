# frozen_string_literal: true

require 'English'

# fileutils is autoloaded by pathname,
# but must be explicitly loaded here for inclusion in `$LOADED_FEATURES`.
require 'fileutils'

before_us = $LOADED_FEATURES.dup
require 'rainbow'

require 'regexp_parser'
require 'set'
require 'stringio'
require 'unicode/display_width'

# we have to require RuboCop's version, before rubocop-ast's
require_relative 'rubocop/version.rb'
require 'rubocop-ast'

require_relative 'concatenated_rubocop.rb'
# Excluded from the concatenation; cops such as `Lint/CopDirectiveSyntax` need it at load time.
require_relative 'rubocop/directive_comment.rb'
require_relative 'rubocop/cop/lint/todo_comment.rb'

unless File.exist?("#{__dir__}/../rubocop.gemspec") # Check if we are a gem
  # Include all of RuboCop's own files, even those that are lazily loaded later (the cops),
  # so that the cache key relies solely on the gem version instead of varying with which
  # cop files end up loaded.
  features = $LOADED_FEATURES - before_us
  RuboCop::ResultCache.rubocop_required_features = features | Dir["#{__dir__}/rubocop/**/*.rb"]
end
RuboCop::AST.rubocop_loaded if RuboCop::AST.respond_to?(:rubocop_loaded)
