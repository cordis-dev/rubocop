# frozen_string_literal: true

# Installs this checkout into the Ruby that runs it, for CodeFactor: `ruby codefactor_install.rb`
# Run it as admin, and again after any gem install or lib change. Runs already in progress keep working.
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative 'lib/rubocop/version'

module CodeFactorInstall
  ROOT = __dir__
  FOLDERS = %w[lib config].freeze

  class << self
    def run(arguments)
      options = parse(arguments)
      step('Install missing gems') { install_gems(options[:gems]) } if options[:gems]
      version = RuboCop::Version::STRING
      gem_dir = options[:gem_dir] || installed_gem_dir(version)
      bin_dir = options[:bin_dir] || RbConfig::CONFIG['bindir']
      lib = File.join(gem_dir, 'lib')

      check_writable(gem_dir)
      staged = step("Copy lib and config next to #{gem_dir}") { FOLDERS.to_h { |folder| [folder, stage(gem_dir, folder)] } }
      step('Concatenate rubocop files') { concatenate(staged['lib']) }
      step('Switch to the new lib and config') { staged.each { |folder, dir| swap(File.join(gem_dir, folder), dir) } }
      step('Build startup snapshot') { build_snapshot(lib) }
      launcher = File.join(bin_dir, 'rubocop.bat')
      step("Write #{launcher}") { write_launcher(launcher, File.join(lib, 'rubocop_fast.rb')) }
      step('Verify') { verify(launcher, version) }
    end

    def parse(arguments)
      options = {}
      until arguments.empty?
        case (argument = arguments.shift)
        when '--gem-dir' then options[:gem_dir] = File.expand_path(arguments.shift)
        when '--bin-dir' then options[:bin_dir] = File.expand_path(arguments.shift)
        when '--gems' then options[:gems] = File.expand_path(arguments.shift)
        else abort "unknown argument #{argument}; usage: ruby codefactor_install.rb [--gems FILE] [--gem-dir DIR] [--bin-dir DIR]"
        end
      end
      options
    end

    def install_gems(list)
      wanted = File.readlines(list, chomp: true).map(&:split).reject(&:empty?)
      missing = wanted.reject { |name, version| Gem::Specification.find_all_by_name(name, version).any? }
      missing.each { |name, version| run_command(File.join(RbConfig::CONFIG['bindir'], 'gem.cmd'), 'install', '--no-document', name, '-v', version) }
      Gem::Specification.reset
      print "#{missing.empty? ? 'none' : missing.map { |name, version| "#{name} #{version}" }.join(', ')}, "
    end

    def installed_gem_dir(version)
      Gem::Specification.find_by_name('rubocop', version).gem_dir
    rescue Gem::MissingSpecError
      abort "rubocop #{version} is not installed; run `gem install --no-document rubocop -v #{version}` first"
    end

    def step(title)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      print "#{title}... "
      result = yield
      puts format('done (%.1f s)', Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      result
    end

    def check_writable(dir)
      probe = File.join(dir, ".codefactor_install_#{Process.pid}")
      File.write(probe, '')
      File.delete(probe)
    rescue SystemCallError => e
      abort "#{e.message}\nRun this from an administrator prompt."
    end

    def stage(gem_dir, folder)
      target = File.join(gem_dir, "#{folder}.new")
      remove(target)
      FileUtils.cp_r(File.join(ROOT, folder), target)
      target
    end

    def concatenate(lib)
      Dir.chdir(lib) do
        run_command(RbConfig.ruby, 'rubocop_bundler.rb', 'rubocop.rb')
        File.delete('rubocop.rb')
        File.rename('rubocop_min.rb', 'rubocop.rb')
      end
    end

    # Two renames, so a run that starts meanwhile sees the old or the new folder, never a partial copy.
    def swap(live, staged)
      old = "#{live}.old"
      remove(old)
      retrying { File.rename(live, old) } if File.exist?(live)
      begin
        retrying { File.rename(staged, live) }
      rescue SystemCallError
        File.rename(old, live) if File.exist?(old) && !File.exist?(live)
        raise
      end
      FileUtils.rm_rf(old)
    end

    def retrying(attempts = 20)
      yield
    rescue SystemCallError
      attempts -= 1
      raise if attempts.zero?

      sleep 0.5
      retry
    end

    def remove(dir)
      FileUtils.rm_rf(dir)
      abort "\nCould not remove #{dir}" if File.exist?(dir)
    end

    def build_snapshot(lib)
      output = run_command(RbConfig.ruby, File.join(lib, 'rubocop_snapshot.rb'))
      summary = output.lines.select { |line| line.start_with?('snapshot:', 'patterns:', 'configs:', 'skipped plugin') }
      print "\n#{summary.map { |line| "  #{line}" }.join}"
    end

    def write_launcher(launcher, script)
      ruby = RbConfig.ruby.tr('/', '\\')
      temp = "#{launcher}.#{Process.pid}.tmp"
      File.binwrite(temp, "@ECHO OFF\r\n@\"#{ruby}\" --disable-gems \"#{script.tr('/', '\\')}\" %*\r\n")
      retrying { File.rename(temp, launcher) }
    end

    def verify(launcher, version)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      output, status = Open3.capture2e({ 'RUBOCOP_FAST_STRICT' => '1' }, 'cmd.exe', '/D', '/C', launcher, '-v')
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
      abort "\nrubocop -v failed:\n#{output}" unless status.success? && output.strip == version

      print format('rubocop -v = %<version>s in %<elapsed>d ms, ', version: version, elapsed: elapsed)
    end

    def run_command(*command)
      output, status = Open3.capture2e(*command)
      abort "\n`#{command.join(' ')}` failed:\n#{output}" unless status.success?

      output
    end
  end
end

CodeFactorInstall.run(ARGV.dup)
