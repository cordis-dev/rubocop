# frozen_string_literal: true

module RuboCop
  # This class represents the cache config of the caching RuboCop runs.
  # @api private
  class CacheConfig
    # The directory within the cache root where the server keeps its state files.
    SERVER_DIR = 'server'

    def self.root_dir
      root = ENV.fetch('RUBOCOP_CACHE_ROOT', nil)
      root ||= yield
      # CodeFactor: ERB is not evaluated, so a templated value is not a usable path.
      root = nil if root.is_a?(String) && root.include?('<%')
      root ||= if ENV.key?('XDG_CACHE_HOME')
                 # Include user ID in the path to make sure the user has write
                 # access.
                 File.join(ENV.fetch('XDG_CACHE_HOME'), Process.uid.to_s)
               else
                 # On FreeBSD, the /home path is a symbolic link to /usr/home
                 # and the $HOME environment variable returns the /home path.
                 #
                 # As $HOME is a built-in environment variable, FreeBSD users
                 # always get a warning message.
                 #
                 # To avoid raising warn log messages on FreeBSD, we retrieve
                 # the real path of the home folder.
                 File.join(File.realpath(Dir.home), '.cache')
               end

      File.join(root, 'rubocop_cache')
    end

    # Lightweight cache root computation that reads CacheRootDirectory from
    # the toplevel config file and environment variables without going through
    # the full ConfigStore/ConfigLoader. This method can be used, for example,
    # before loading configuration files. Please note that this method doesn't
    # take into account any `inherit_from` dependencies.
    def self.root_dir_from_toplevel_config(cache_root_override = nil)
      root_dir do
        next cache_root_override if cache_root_override

        config_path = ConfigFinder.find_config_path(PathUtil.pwd)
        file_contents = File.read(config_path)

        # Returns early if `CacheRootDirectory` is not used before requiring `yaml`.
        next unless file_contents.include?('CacheRootDirectory')

        require 'yaml'
        config_yaml = load_yaml(file_contents, config_path)
        # Also covers Psych < 4 (Ruby 3.0 or lower), which returns `false` for an empty document.
        all_cops = config_yaml['AllCops'] if config_yaml.is_a?(Hash)
        next unless all_cops.is_a?(Hash)

        all_cops['CacheRootDirectory']
      end
    end

    # CodeFactor: plain YAML, no ERB (see ConfigLoader). The cache-root lookup is best-effort:
    # a config that does not parse falls back to the default root, and the full config load
    # reports the error.
    def self.load_yaml(contents, path)
      YAML.safe_load(contents, permitted_classes: [Regexp, Symbol], aliases: true, filename: path)
    rescue Psych::Exception
      nil
    end
    private_class_method :load_yaml
  end
end
