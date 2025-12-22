# frozen_string_literal: true

module RuboCop
  module Cop
    module Lint
      # Flags TODO-style comments purely for existing (not formatting).
      class TodoComment < Base
        MSG = 'TODO-style comment found. Remove it or convert it to a ticket.'.freeze

        def on_new_investigation
          keywords = Array(cop_config['Keywords'] || %w[TODO FIXME]).map(&:to_s)
          return if keywords.empty?

          processed_source.comments.each do |comment|
            text = comment.text

            # Case-sensitive, keyword must appear after '#'
            keyword = keywords.find do |k|
              text.match?(/^\s*#\s*#{Regexp.escape(k)}\b/)
            end

            next unless keyword

            add_offense(comment, message: format(MSG, keyword: keyword))
          end
        end
      end
    end
  end
end
