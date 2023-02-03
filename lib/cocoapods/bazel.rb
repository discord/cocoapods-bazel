# frozen_string_literal: true

require 'starlark_compiler/build_file'
require 'cocoapods/bazel/config'
require 'cocoapods/bazel/target'
require 'cocoapods/bazel/xcconfig_resolver'
require 'cocoapods/bazel/util'
require 'pathname'
require 'json'
require 'xcodeproj/constants'

def fixup_attr(obj, pod_root)
  if obj.is_a? Pathname
    begin
      obj.relative_path_from(pod_root).to_s
    rescue Exception
      "FAILED: #{obj} #{pod_root}"
    end
  elsif obj.is_a? Array
    obj.map { |i| fixup_attr(i, pod_root) }
  else
    obj
  end
end


def get_attrs(obj, pod_root)
  _TO_IGNORE = [:spec, :specs, :subspec, :subspecs]
  obj
    .class
    .instance_methods(false)
    .filter { |name| !_TO_IGNORE.include? name }
    .map { |name| obj.method(name) } \
    # Can we call this with no arguments?
    .filter { |method| method.parameters.all? { |(type, _)| type != :req && type != :keyreq && type != :block } } \
    # .map { |method| [method.name.to_s, fixup_attr(method.call(), pod_root)] }
    .map { |method| [method.name.to_s, method.call()] }
    .to_h
end

module Pod
  module Bazel

    def self.post_install(installer:)
      return unless (config = Config.from_podfile(installer.podfile))

      default_xcconfigs = config.default_xcconfigs.transform_values do |xcconfig|
        _name, xcconfig = XCConfigResolver.resolve_xcconfig(xcconfig)
        xcconfig
      end

      UI.titled_section 'Generating Bazel files' do
        workspace = installer.config.installation_root
        sandbox = installer.sandbox

        # Ensure we declare the sandbox (Pods/) as a package so each Pod (as a package) belongs to sandbox root package instead
        FileUtils.touch(File.join(installer.config.sandbox_root, 'BUILD.bazel'))
        build_files_dir = File.join(installer.config.sandbox_root, 'build_files')
        FileUtils.mkdir_p(build_files_dir)

        build_file_packages = {}
        installer.pod_targets.each do |pod_target|
          package_absolute = File.join(build_files_dir, pod_target.name)
          FileUtils.mkdir_p(package_absolute)
          package = Pathname.new(package_absolute).relative_path_from(workspace).to_s
          # puts(package_absolute, package)
          # package = sandbox.pod_dir(pod_target.pod_name).relative_path_from(workspace).to_s
          if package.start_with?('..')
            # puts pod_target.name
            # puts sandbox.pod_dir(pod_target.pod_name)
            # puts workspace
            # puts File.join(installer.config.sandbox_root, 
            raise Informative, <<~MSG
              Bazel does not support Pod located outside of current workspace: \"#{package}\".
              To fix this, you can move the Pod into workspace,
              or you can symlink the Pod inside the workspace by running `ln -s <path_to_pod> .` at workspace root
              Then change path declared in Podfile to `./<pod_name>`
              Current workspace: #{workspace}
            MSG
          end

          build_file = StarlarkCompiler::BuildFile.new(workspace: workspace, package: package)
          build_file_packages[pod_target.name] = File.join(workspace, package, 'BUILD.bazel')

          targets_without_library_specification = pod_target.file_accessors.reject { |fa| fa.spec.library_specification? }.map do |fa|
            Target.new(
              installer,
              pod_target,
              fa.spec,
              default_xcconfigs,
              config.experimental_deps_debug_and_release
            )
          end

          default_target = Target.new(
            installer,
            pod_target,
            nil,
            default_xcconfigs,
            config.experimental_deps_debug_and_release
          )

          bazel_targets = [default_target] + targets_without_library_specification

          pod_root = installer.sandbox.pod_dir(pod_target.pod_name)

          info = get_attrs(pod_target, pod_root)
          info["file_accessors"] = pod_target.file_accessors.map { |fa|
            fa_info = get_attrs(fa, pod_root)
            fa_info["spec_consumer"] = get_attrs(fa.spec_consumer, pod_root)
            fa_info
          }

          File.write(File.join(package_absolute, "info.json"), JSON.pretty_generate(info))
          bazel_targets.each do |t|
            load = config.load_for(macro: t.type)
            build_file.add_load(of: load[:rule], from: load[:load])
            build_file.add_target StarlarkCompiler::AST::FunctionCall.new(load[:rule], **t.to_rule_kwargs)
          end
          build_file.save!()
        end

        format_files(build_files: build_file_packages.values, buildifier: config.buildifier, workspace: workspace)
        unless config.build_file_doc.empty?
          build_file_packages.each_value do |path|
            content = File.read(path)
            File.write(path, "\"\"\"\n#{config.build_file_doc}\n\"\"\"\n\n" + content)
          end
        end

        config.build_file_patches.each do |pod_name, patch_file|
          patch_file_path = File.absolute_path(patch_file)
          build_file_path = build_file_packages[pod_name]
          Pod::Executable.execute_command(
            "bash",
            ["-c", "cd #{File.dirname(build_file_path)} && /usr/bin/patch -p1 < #{patch_file_path}"],
            true,
          )
        end

        cocoapods_bazel_path = File.join(sandbox.root, 'cocoapods-bazel')
        FileUtils.mkdir_p cocoapods_bazel_path

        write_cocoapods_bazel_build_file(cocoapods_bazel_path, workspace, config)
        write_non_empty_default_xcconfigs(cocoapods_bazel_path, default_xcconfigs)
      end
    end

    def self.write_cocoapods_bazel_build_file(path, workspace, config)
      FileUtils.touch(File.join(path, 'BUILD.bazel'))

      cocoapods_bazel_pkg = Pathname.new(path).relative_path_from Pathname.new(workspace)
      configs_build_file = StarlarkCompiler::BuildFile.new(workspace: workspace, package: cocoapods_bazel_pkg)
      configs_build_file.add_load(of: 'string_flag', from: '@bazel_skylib//rules:common_settings.bzl')
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('string_flag', name: 'config', build_setting_default: 'debug', visibility: ['//visibility:public'])
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'debug', flag_values: { ':config' => 'debug' }, visibility: ['//visibility:public'])
      configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('config_setting', name: 'release', flag_values: { ':config' => 'release' }, visibility: ['//visibility:public'])

      if config.experimental_deps_debug_and_release
        configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new('string_flag', name: 'deps_config', build_setting_default: 'deps_debug', visibility: ['//visibility:public'])
        configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new(
          'config_setting', name: 'deps_debug', flag_values: { ':deps_config' => 'deps_debug' }, visibility: ['//visibility:public']
        )
        configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new(
          'config_setting', name: 'deps_release', flag_values: { ':deps_config' => 'deps_release' }, visibility: ['//visibility:public']
        )
        configs_build_file.add_target StarlarkCompiler::AST::FunctionCall.new(
          'config_setting', name: 'deps_debug_and_release', flag_values: { ':deps_config' => 'deps_debug_and_release' }, visibility: ['//visibility:public']
        )
      end

      configs_build_file.save!
      format_files(build_files: [configs_build_file], buildifier: config.buildifier, workspace: workspace)
    end

    def self.write_non_empty_default_xcconfigs(path, default_xcconfigs)
      return if default_xcconfigs.empty?

      hash = StarlarkCompiler::AST.new(toplevel: [StarlarkCompiler::AST::Dictionary.new(default_xcconfigs)])

      File.open(File.join(path, 'default_xcconfigs.bzl'), 'w') do |f|
        f << <<~STARLARK
          """
          Default xcconfigs given as options to cocoapods-bazel.
          """

        STARLARK
        f << 'DEFAULT_XCCONFIGS = '
        StarlarkCompiler::Writer.write(ast: hash, io: f)
      end
    end

    def self.format_files(build_files:, buildifier:, workspace:)
      return if build_files.empty?

      args = []
      case buildifier
      when true
        return unless Pod::Executable.which('buildifier')

        args = ['buildifier']
      when String, Array
        args = Array(buildifier)
      else
        return
      end
      args += %w[-type build]

      executable, *args = args
      Pod::Executable.execute_command executable,
                                      args + build_files,
                                      true
    end
  end
end
