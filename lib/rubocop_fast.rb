# frozen_string_literal: true

# Starts RuboCop from a snapshot built by rubocop_snapshot.rb. Run it with `ruby --disable-gems`.
module RuboCopFast
  SNAPSHOT_PATH = File.join(__dir__, 'rubocop_snapshot.bin')

  class << self
    def run
      header, body = read_snapshot
      unless header
        abort "#{SNAPSHOT_PATH} is missing or stale, run rubocop_snapshot.rb" if ENV['RUBOCOP_FAST_STRICT']
        return run_without_snapshot
      end

      install(header, body)
      require 'rubocop'
      ConfigCache.install(body)
      exit RuboCop::CLI.new.run
    end

    def read_snapshot
      File.open(SNAPSHOT_PATH, 'rb') do |file|
        header = Marshal.load(file.read(file.read(8).unpack1('Q<')))
        return unless fresh?(header)

        body = Marshal.load(file.read(file.read(8).unpack1('Q<')))
        blob_start = file.pos
        [header, body.merge(blob_start: blob_start, hot: file.read(header[:groups][0][1]),
                            stamp: stamp_of(SNAPSHOT_PATH))]
      end
    rescue StandardError
      nil
    end

    def fresh?(header)
      header[:ruby] == RUBY_DESCRIPTION && header[:watch].all? { |path, stamp| stamp_of(path) == stamp }
    end

    def stamp_of(path)
      stat = File.stat(path)
      [stat.size, stat.mtime.to_i]
    rescue SystemCallError
      nil
    end

    def run_without_snapshot
      require 'rubygems'
      require_relative 'rubocop/version'
      load Gem.activate_bin_path('rubocop', 'rubocop', "= #{RuboCop::Version::STRING}")
    end

    def install(header, body)
      # Keep entries added at run time (RUBYLIB, -I) in front of the snapshot's load path.
      extra = $LOAD_PATH.map { |dir| File.expand_path(dir) } - header[:load_path]
      $LOAD_PATH.replace(extra + header[:load_path])
      LoadPath.setup(header)
      PatternCache.setup(header, body)
      Loader.setup(header, body)
      Kernel.prepend(Loader::Require)
      require 'fiddle'
      Loader.enable_provide(header[:libruby])
      GemStub.setup(body)
    end
  end

  module LoadPath
    class << self
      def setup(header)
        @gem_dirs = header[:gem_dirs]
        @rank = header[:full_load_path].each_with_index.to_h
        @active = {}
      end

      def activate(gem_name)
        return if @active[gem_name] || !@gem_dirs.key?(gem_name)

        @active[gem_name] = true
        @gem_dirs[gem_name].each { |dir| add(dir) }
      end

      def activate_all
        @gem_dirs.each_key { |gem_name| activate(gem_name) }
      end

      def add(dir)
        rank = @rank[dir]
        return if rank.nil? || $LOAD_PATH.include?(dir)

        position = $LOAD_PATH.index { |entry| (other = @rank[entry]) && other > rank } || $LOAD_PATH.size
        $LOAD_PATH.insert(position, dir)
      end
    end
  end

  module Loader
    class << self
      def setup(header, body)
        @index = body[:index]
        @iseqs = body[:iseqs]
        @owners = body[:owners]
        @groups = header[:groups]
        @blob_start = body[:blob_start]
        @stamp = body[:stamp]
        @group_data = { 0 => body[:hot] }
        @loaded = {}
        @known = 0
        @lock = Thread::Mutex.new
        @unprovided = []
        sync
      end

      # Files loaded before Fiddle is ready (Fiddle's own) are registered once rb_provide can be called.
      def enable_provide(libruby)
        library = Fiddle::Handle.new(libruby)
        @provide = Fiddle::Function.new(library['rb_provide'], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_VOID, need_gvl: true)
        synchronize do
          sync
          @unprovided.each { |path| provide(path) }
          @unprovided = nil
        end
      end

      def path_for(name)
        feature = name.delete_suffix('.rb')
        return @index[feature] unless feature.start_with?('/') || feature[1] == ':'

        path = "#{feature}.rb"
        path if @iseqs.key?(path)
      end

      def load(path)
        synchronize do
          sync if $LOADED_FEATURES.size != @known
          return false if @loaded[path]

          @loaded[path] = true
          owner = @owners[path]
          LoadPath.activate(owner) if owner
          @provide ? provide(path) : @unprovided << path
          evaluate(path)
          PatternCache.loaded(path)
          true
        end
      end

      # rb_provide registers the feature without the realpath rebuild a Ruby-level `$LOADED_FEATURES <<` causes.
      def provide(path)
        @provide.call(path)
        @known += 1
      end

      def synchronize(&)
        @lock.owned? ? yield : @lock.synchronize(&)
      end

      def evaluate(path)
        group, offset, length = @iseqs[path]
        RubyVM::InstructionSequence.load_from_binary(group_data(group).byteslice(offset, length)).eval
      rescue Exception # rubocop:disable Lint/RescueException
        @loaded.delete(path)
        $LOADED_FEATURES.delete(path)
        raise
      end

      def group_data(id)
        @group_data[id] ||= begin
          # A reinstall replaces the snapshot by path, so the offsets read at startup would point at other code.
          unless RuboCopFast.stamp_of(SNAPSHOT_PATH) == @stamp
            raise "#{SNAPSHOT_PATH} was replaced during this run; run rubocop again"
          end

          start, size = @groups[id]
          File.binread(SNAPSHOT_PATH, size, @blob_start + start)
        end
      end

      def sync
        $LOADED_FEATURES.drop(@known).each { |feature| @loaded[feature] = true }
        @known = $LOADED_FEATURES.size
      end
    end

    module Require
      private

      def require(name)
        path = Loader.path_for(name)
        return Loader.load(path) if path

        begin
          super
        rescue LoadError
          raise if GemStub.full?

          GemStub.load_rubygems
          super
        end
      end

      def require_relative(name)
        base = caller_locations(1, 1)[0].absolute_path
        return super unless base

        absolute = File.expand_path(name, File.dirname(base))
        path = Loader.path_for(absolute)
        path ? Loader.load(path) : require(absolute)
      end

      def gem(name, *requirements)
        unless GemStub.full?
          if GemStub.known?(name)
            LoadPath.activate(name)
            return true
          end

          GemStub.load_rubygems
        end
        super
      end
    end
  end

  # Reuses the Ruby source that rubocop-ast generated for each node pattern at build time.
  module PatternCache
    class << self
      def setup(header, body)
        @hook = header[:pattern_hook]
        @blob = body[:patterns]
      end

      def loaded(path)
        return unless path == @hook

        @sources, sets = Marshal.load(@blob)
        @blob = nil
        restore_sets(sets)
        RuboCop::AST::NodePattern::Macros.prepend(Macros)
      end

      def restore_sets(sets)
        holder = RuboCop::AST::NodePattern::Sets
        sets.each do |set, constant|
          name = constant.split('::').last
          holder.const_set(name, set) unless holder.const_defined?(name, false)
          holder::REGISTRY[set] = constant
        end
      end

      def define(base, kind, method_name, pattern, defaults, location)
        name = defaults.empty? ? method_name : :"without_defaults_#{method_name}"
        source = pattern.is_a?(String) && @sources[[kind, name, pattern]]
        return unless source

        unless defaults.empty?
          base.send(:define_method, method_name) { |*args, **values| send(name, *args, **defaults, **values) }
        end
        base.class_eval(source, location.path, location.lineno)
        name
      end
    end

    module Macros
      def def_node_matcher(method_name, pattern_str, **keyword_defaults)
        PatternCache.define(self, :matcher, method_name, pattern_str, keyword_defaults, caller_locations(1, 1)[0]) ||
          super
      end

      def def_node_search(method_name, pattern_str, **keyword_defaults)
        PatternCache.define(self, :search, method_name, pattern_str, keyword_defaults, caller_locations(1, 1)[0]) ||
          super
      end
    end
  end

  # Reuses parsed YAML of the config files shipped inside gems while they are unchanged.
  module ConfigCache
    class << self
      def install(body)
        @configs = body[:configs]
        RuboCop::ConfigLoader.singleton_class.prepend(Loading)
      end

      def fetch(path)
        path = File.expand_path(path)
        stamp, data = @configs[path]
        Marshal.load(data) if stamp && RuboCopFast.stamp_of(path) == stamp
      end
    end

    module Loading
      def load_yaml_configuration(absolute_path)
        hash = ConfigCache.fetch(absolute_path)
        return super unless hash

        puts "configuration from #{absolute_path}" if debug?
        hash
      end
    end
  end

  module GemStub
    class << self
      def setup(body)
        @specs = body[:specs]
        @spec_fields = body[:light_specs]
        @full = false
        Object.const_set(:Gem, Module.new) unless defined?(::Gem)
        %w[Version Requirement Deprecate].each do |name|
          ::Gem.autoload name, Loader.path_for("rubygems/#{name.downcase}")
        end
        ::Gem.singleton_class.prepend(Missing)
      end

      def full?
        @full
      end

      def known?(gem_name)
        @spec_fields.key?(gem_name)
      end

      def load_rubygems
        return if @full

        @full = true
        LoadPath.activate_all
        require 'rubygems'
        ::Gem.loaded_specs.merge!(Marshal.load(@specs))
      end

      def light_specs
        @light_specs ||= @spec_fields.to_h { |name, fields| [name, LightSpec.new(name, fields)] }
      end

      def full_spec(name)
        load_rubygems
        ::Gem.loaded_specs[name]
      end
    end

    # Answers what RuboCop reads from a loaded gem spec (metadata, version, paths) without RubyGems.
    class LightSpec
      attr_reader :name, :metadata, :full_gem_path, :gem_dir, :require_paths, :full_require_paths

      def initialize(name, fields)
        @name = name
        @version = fields[:version]
        @metadata = fields[:metadata]
        @full_gem_path = fields[:full_gem_path]
        @gem_dir = fields[:gem_dir]
        @require_paths = fields[:require_paths]
        @full_require_paths = fields[:full_require_paths]
      end

      def version
        @version_object ||= ::Gem::Version.new(@version)
      end

      def method_missing(name, ...)
        GemStub.full_spec(@name).public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        GemStub.full_spec(@name).respond_to?(name, include_private)
      end
    end

    module Missing
      def loaded_specs
        GemStub.full? ? super : GemStub.light_specs
      end

      def method_missing(name, ...)
        return super if GemStub.full?

        GemStub.load_rubygems
        public_send(name, ...)
      end

      def respond_to_missing?(name, include_private = false)
        return super if GemStub.full?

        GemStub.load_rubygems
        respond_to?(name, include_private)
      end

      def const_missing(name)
        return super if GemStub.full?

        GemStub.load_rubygems
        const_get(name)
      end
    end
  end
end

RuboCopFast.run
