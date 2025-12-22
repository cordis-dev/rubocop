#!/usr/bin/env ruby

require 'pathname'
require 'set'

class RubocopConcatenator
  def initialize(rubocop_file_path, output_file_path = 'concatenated_rubocop.rb')
    @rubocop_file_path = Pathname.new(rubocop_file_path)
    @output_file_path = Pathname.new(output_file_path)
    @base_dir = @rubocop_file_path.dirname
    @processed_files = Set.new
    @excluded_files = [
      'rubocop/cli/command/lsp.rb',
      'rubocop/version.rb',
	  'rubocop/directive_comment.rb'
    ]
  end

  def concatenate
    puts "Reading rubocop.rb from: #{@rubocop_file_path}"
    puts "Output will be written to: #{@output_file_path}"
    
    unless @rubocop_file_path.exist?
      puts "Error: #{@rubocop_file_path} does not exist!"
      return false
    end

    File.open(@output_file_path, 'w') do |output|
      # Process all require_relative files in order
      process_require_relatives(output)
    end
    
    puts "Concatenation complete! Output written to: #{@output_file_path}"
    puts "Total files processed: #{@processed_files.size}"
    true
  end

  private

  def process_require_relatives(output)
    require_relatives = extract_require_relatives
    
    puts "Found #{require_relatives.size} require_relative statements"
    
    require_relatives.each_with_index do |relative_path, index|
      puts "Processing #{index + 1}/#{require_relatives.size}: #{relative_path}"
      process_single_file(relative_path, output)
    end
  end

  def extract_require_relatives
    require_relatives = []
    
    File.readlines(@rubocop_file_path).each do |line|
      line = line.strip
      if line.start_with?('require_relative')
        # Extract the path from require_relative 'path'
        if match = line.match(/require_relative\s+['"]([^'"]+)['"]/)
          path = match[1]
          # Remove .rb extension if present and add it back to ensure consistency
          path = path.sub(/\.rb$/, '') + '.rb'
          require_relatives << path
        end
      end
    end
    
    require_relatives
  end

  def comment_only_line?(line)
    # Remove leading and trailing whitespace
    trimmed = line.strip
    
    # Empty line, line that is just # (empty comment), or line that starts with # followed by space
    trimmed.empty? || trimmed == '#' || trimmed.start_with?('# ')
  end

  def process_single_file(relative_path, output)
    # Skip excluded files
    if @excluded_files.include?(relative_path)
      puts "Skipping excluded file: #{relative_path}"
      return
    end
    
    file_path = @base_dir + relative_path
    
    # Track processed files to avoid duplicates
    canonical_path = file_path.expand_path.to_s
    if @processed_files.include?(canonical_path)
      return
    end
    
    @processed_files.add(canonical_path)
    
    if file_path.exist?
      begin
        # Get the directory of the current file being processed (relative to base)
        current_file_dir = Pathname.new(relative_path).dirname
        
        File.readlines(file_path).each do |line|
          # Skip comment-only lines
          next if comment_only_line?(line)
          
          # Replace File.realpath pattern
          line = line.gsub(
            "File.realpath(File.join(File.dirname(__FILE__), '..', '..'))",
            "File.realpath(File.join(File.dirname(__FILE__), '..'))"
          )
		  
		  # Replace rubocop_extra_features lib path
		  line = line.gsub(
		    "lib_root = File.join(File.dirname(__FILE__), '..')",
			"lib_root = File.dirname(__FILE__)"
		  )
          
          # Check if this line contains a require_relative
          if line.strip.start_with?('require_relative') && (match = line.match(/require_relative\s+['"]([^'"]+)['"]/))
            required_path = match[1]
            # Remove .rb extension if present for path calculation
            required_path_no_ext = required_path.sub(/\.rb$/, '')
            
            # Calculate the path relative to the base directory
            if current_file_dir.to_s == '.'
              # If current file is in base directory, path doesn't change
              updated_path = required_path_no_ext
            else
              # Combine current file's directory with the required path
              updated_path = (current_file_dir + required_path_no_ext).to_s
            end
            
            # Update the line with the new path, preserving original quote style
            quote_char = match[0].include?('"') ? '"' : "'"
            updated_line = line.gsub(/require_relative\s+['"]([^'"]+)['"]/, "require_relative #{quote_char}#{updated_path}#{quote_char}")
            output.write updated_line
          else
            output.write line
          end
        end
      rescue => e
        puts "Warning: Could not read #{file_path}: #{e.message}"
      end
    else
      puts "Warning: File not found: #{file_path}"
    end
  end
end

# Usage
if ARGV.empty?
  puts "Usage: ruby #{$0} <path_to_rubocop.rb> [output_file]"
  puts "Example: ruby #{$0} rubocop.rb concatenated_rubocop.rb"
  exit 1
end

rubocop_file = ARGV[0]
output_file = ARGV[1] || 'concatenated_rubocop.rb'

concatenator = RubocopConcatenator.new(rubocop_file, output_file)
success = concatenator.concatenate

exit(success ? 0 : 1)