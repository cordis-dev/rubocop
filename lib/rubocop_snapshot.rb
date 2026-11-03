# frozen_string_literal: true

# Builds rubocop_snapshot.bin for rubocop_fast.rb. Run it with plain `ruby` after every gem or lib change.
require 'rbconfig'
require 'set'
require 'tmpdir'
require 'fileutils'
require_relative 'rubocop/version'

module RuboCopSnapshot
  OUTPUT = File.join(__dir__, 'rubocop_snapshot.bin')
  PRECOMPILED_GEMS = %w[ast lint_roller parser prism regexp_parser rubocop-ast].freeze
  LAZY_FEATURES = %w[unicode/display_width uri digest/sha1 zlib find erb].freeze
  SAMPLE_SOURCE = <<~RUBY
    # frozen_string_literal: true

    class Sample
      def call(items)
        items.map { |item| item.to_s * 2 }
      end
    end
  RUBY

  class << self
    def build
      activate_rubocop
      record_patterns
      require 'rubocop'
      exercise_rubocop
      @hot_files = Set.new($LOADED_FEATURES)
      core_load_path = expanded_load_path
      plugins = require_plugins
      load_all_cops
      @configs = parse_configs
      write_snapshot(core_load_path, plugins)
    end

    def activate_rubocop
      require 'fiddle'
      # This version, not the newest installed one, so the dependencies match this copy of RuboCop.
      Gem.activate_bin_path('rubocop', 'rubocop', "= #{RuboCop::Version::STRING}")
      @installed_lib = File.expand_path(Gem.loaded_specs['rubocop'].full_require_paths.first)
      index = $LOAD_PATH.index(@installed_lib)
      $LOAD_PATH[index] = __dir__ if index
    end

    def record_patterns
      @patterns = {}
      recorder = pattern_recorder(@patterns)
      trace = TracePoint.new(:end) do |point|
        next unless point.self.is_a?(Module) && point.self.name == 'RuboCop::AST::NodePattern::MethodDefiner'

        point.self.prepend(recorder)
        trace.disable
      end
      trace.enable
    end

    def pattern_recorder(patterns)
      Module.new do
        define_method(:def_helper) do |base, method_name, **defaults, &block|
          kind = caller_locations(1, 1)[0].label.end_with?('def_node_search') ? :search : :matcher
          super(base, method_name, **defaults) do |name|
            block.call(name).tap do |source|
              key = [kind, name, pattern]
              patterns[key] = patterns.key?(key) && patterns[key] != source ? nil : source
            end
          end
        end
        private :def_helper
      end
    end

    def parse_configs
      roots = Gem.loaded_specs.values.select { |spec| spec.name.start_with?('rubocop-') }.map(&:full_gem_path)
      roots << File.expand_path('..', __dir__)
      roots.flat_map { |root| Dir["#{root}/config/**/*.yml"] }.each_with_object({}) do |path, configs|
        path = File.expand_path(path)
        next if File.read(path).include?('<%')

        configs[path] = [stamp_of(path), Marshal.dump(RuboCop::ConfigLoader.load_yaml_configuration(path))]
      rescue StandardError => e
        warn "config not cached: #{path} (#{e.class})"
      end
    end

    def load_all_cops
      Dir.mktmpdir('rubocop-snapshot') { |dir| Dir.chdir(dir) { run_cli(%w[--show-cops]) } }
    end

    def require_plugins
      Gem::Specification.latest_specs(true).select { |spec| spec.name.start_with?('rubocop-') }.filter_map do |spec|
        feature = [spec.name, spec.name.tr('-', '/')].find { |name| try_require(name) }
        warn "skipped plugin #{spec.full_name}" unless feature
        feature
      end
    end

    def try_require(name)
      require name
      true
    rescue LoadError, StandardError
      false
    end

    def exercise_rubocop
      Dir.mktmpdir('rubocop-snapshot') do |dir|
        File.write(File.join(dir, 'sample.rb'), SAMPLE_SOURCE)
        File.write(File.join(dir, '.rubocop.yml'), "AllCops:\n  NewCops: enable\n  UseCache: false\n")
        Dir.chdir(dir) do
          run_cli(%w[--no-parallel --format json sample.rb])
          run_cli(%w[--format json --autocorrect-all sample.rb])
        end
      end
      LAZY_FEATURES.each { |feature| require feature }
    end

    def run_cli(arguments)
      stdout = $stdout
      $stdout = StringIO.new
      RuboCop::CLI.new.run(arguments)
    ensure
      $stdout = stdout
    end

    def expanded_load_path
      $LOAD_PATH.map { |dir| File.expand_path(dir) }
    end

    def write_snapshot(core_load_path, plugins)
      load_path = expanded_load_path
      gem_dirs = optional_gem_dirs(core_load_path, load_path)
      iseqs = compile(source_files)
      file_owners = owners(iseqs.keys, gem_dirs)
      locations, groups, blob = layout(iseqs, file_owners)
      header = {
        groups: groups,
        ruby: RUBY_DESCRIPTION,
        libruby: RbConfig::CONFIG['LIBRUBY_SO'],
        load_path: core_load_path,
        full_load_path: load_path,
        gem_dirs: gem_dirs,
        pattern_hook: RuboCop::AST::NodePattern::Sets.method(:[]).source_location[0],
        watch: watch_list(load_path).to_h { |path| [path, stamp_of(path)] }
      }
      patterns = @patterns.compact
      body = { index: index(iseqs.keys, load_path), iseqs: locations, owners: file_owners,
               specs: Marshal.dump(Gem.loaded_specs.to_h), light_specs: light_specs,
               configs: @configs,
               patterns: Marshal.dump([patterns, RuboCop::AST::NodePattern::Sets::REGISTRY.to_a]) }
      save(header, body, blob)
      warn "plugins: #{plugins.join(', ')}"
      warn "configs: #{@configs.size}"
      warn "patterns: #{patterns.size} (#{@patterns.count { |_, source| source.nil? }} ambiguous)"
      warn "snapshot: #{iseqs.size} files, #{File.size(OUTPUT) / 1024} KB -> #{OUTPUT}"
    end

    def layout(iseqs, file_owners)
      grouped = iseqs.group_by { |path, _| @hot_files.include?(path) ? :hot : file_owners.fetch(path, :rest) }
      names = [:hot] + (grouped.keys - [:hot])
      blob = String.new(encoding: Encoding::BINARY)
      locations = {}
      groups = names.each_with_index.map do |name, id|
        start = blob.bytesize
        grouped.fetch(name, []).each do |path, binary|
          locations[path] = [id, blob.bytesize - start, binary.bytesize]
          blob << binary
        end
        [start, blob.bytesize - start]
      end
      [locations, groups, blob]
    end

    def light_specs
      Gem.loaded_specs.transform_values do |spec|
        { version: spec.version.to_s, metadata: spec.metadata, full_gem_path: spec.full_gem_path,
          gem_dir: spec.gem_dir, require_paths: spec.require_paths, full_require_paths: spec.full_require_paths }
      end
    end

    def optional_gem_dirs(core_load_path, load_path)
      Gem.loaded_specs.each_with_object({}) do |(name, spec), dirs|
        next if ((require_dirs(spec) & load_path) - core_load_path).empty?

        dirs[name] = ((dependency_dirs(spec) & load_path) - core_load_path).uniq
      end
    end

    def dependency_dirs(spec, seen = Set.new)
      return [] unless seen.add?(spec.name)

      require_dirs(spec) + spec.runtime_dependencies.flat_map do |dependency|
        loaded = Gem.loaded_specs[dependency.name]
        loaded ? dependency_dirs(loaded, seen) : []
      end
    end

    def require_dirs(spec)
      spec.full_require_paths.map { |dir| File.expand_path(dir) }.map { |dir| dir == @installed_lib ? __dir__ : dir }
    end

    def owners(paths, gem_dirs)
      own_dirs = gem_dirs.keys.flat_map { |name| require_dirs(Gem.loaded_specs[name]).map { |dir| [dir, name] } }
      paths.each_with_object({}) do |path, owners|
        owner = own_dirs.find { |dir, _| path.start_with?("#{dir}/") }
        owners[path] = owner[1] if owner
      end
    end

    def source_files
      files = Set.new($LOADED_FEATURES.select { |path| path.end_with?('.rb') && File.file?(path) })
      precompiled_dirs.each { |dir| Dir["#{dir}/**/*.rb"].each { |path| files << File.expand_path(path) } }
      Dir["#{RbConfig::CONFIG['rubylibdir']}/rubygems/**/*.rb"].each do |path|
        files << path unless path.include?('/vendor/')
      end
      files
    end

    def precompiled_dirs
      specs = Gem.loaded_specs.values.select do |spec|
        spec.name == 'rubocop' || spec.name.start_with?('rubocop-') || PRECOMPILED_GEMS.include?(spec.name)
      end
      specs.flat_map { |spec| require_dirs(spec) }
    end

    def compile(files)
      files.each_with_object({}) do |path, iseqs|
        iseqs[path] = RubyVM::InstructionSequence.compile_file(path).to_binary
      rescue SyntaxError, StandardError => e
        warn "not precompiled: #{path} (#{e.class})"
      end
    end

    def index(paths, load_path)
      paths.each_with_object({}) do |path, names|
        load_path.each do |dir|
          next unless path.start_with?("#{dir}/")

          name = path[(dir.size + 1)..].delete_suffix('.rb')
          names[name] ||= path if $LOAD_PATH.resolve_feature_path(name)&.last == path
        end
      end
    end

    def watch_list(load_path)
      gem_roots = load_path.filter_map do |dir|
        position = dir.rindex('/gems/')
        dir[0, position] if position
      end
      [File.join(__dir__, 'rubocop.rb'), File.join(__dir__, 'concatenated_rubocop.rb'), __FILE__,
       File.join(__dir__, 'rubocop_fast.rb')] + gem_roots.uniq.map { |root| File.join(root, 'specifications') }
    end

    def stamp_of(path)
      stat = File.stat(path)
      [stat.size, stat.mtime.to_i]
    rescue SystemCallError
      nil
    end

    def save(header, body, blob)
      header_data = Marshal.dump(header)
      body_data = Marshal.dump(body)
      temp = "#{OUTPUT}.#{Process.pid}.tmp"
      File.open(temp, 'wb') do |file|
        file.write([header_data.bytesize].pack('Q<'), header_data, [body_data.bytesize].pack('Q<'), body_data, blob)
      end
      FileUtils.mv(temp, OUTPUT)
    end
  end
end

RuboCopSnapshot.build
