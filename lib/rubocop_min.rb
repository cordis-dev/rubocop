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
require_relative 'rubocop/cop/lint/todo_comment.rb'

unless File.exist?("#{__dir__}/../rubocop.gemspec") # Check if we are a gem
  RuboCop::ResultCache.rubocop_required_features = $LOADED_FEATURES - before_us
end
RuboCop::AST.rubocop_loaded if RuboCop::AST.respond_to?(:rubocop_loaded)
