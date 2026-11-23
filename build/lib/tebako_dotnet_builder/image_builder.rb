# frozen_string_literal: true

# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

require "fileutils"
require "open3"

module TebakoDotnetBuilder
  # Stage the env-image tree from Microsoft's SDK archive (the repack
  # step): extract pristine, prune to the declared scope, stage the
  # POSIX preload shim, and render the two tebako cards (the tier-1
  # payload manifest at /__tpkg__/manifest.yaml and the layout
  # declaration at /lib/tebako/layout.yaml). The prune policy is
  # documented in docs/build-chain.md — every pruned path is asserted
  # ABSENT and every kept path asserted PRESENT, so an SDK bump whose
  # tree shape drifted is a named build error, never a silent scope
  # change.
  class ImageBuilder
    # The declared skeleton scope is the console/classlib build+run
    # toolchain. Pruned (all present in the pinned archive, re-addable
    # by recipe edit when their increment lands):
    #   shared/Microsoft.AspNetCore.App + packs/Microsoft.AspNetCore.App.Ref
    #     — the ASP.NET web workload: out of the skeleton's declared
    #       scope; the web workload is its own increment.
    #   sdk/<ver>/TestHostNetFramework
    #     — vstest's .NET Framework test host: .NET Framework is the
    #       windows-only legacy line, never this cross-platform
    #       runtime's scope; dead bytes on every tebako target.
    PRUNE_PATHS = %w[
      shared/Microsoft.AspNetCore.App
      packs/Microsoft.AspNetCore.App.Ref
    ].freeze

    PRUNE_SDK_PATHS = %w[
      TestHostNetFramework
    ].freeze

    # The kept surface the read-back asserts (the skeleton scope's
    # evidence): the muxer, the fxr handoff, the shared runtime, the
    # offline compile packs, the SDK itself, the workload grammar, the
    # templates, and the license carriage. The apphost pack is asserted
    # per-RID (Microsoft.NETCore.App.Host.<rid>).
    def initialize(pins:, version:, triplet:, work_dir:, tar: "tar")
      @pins = pins
      @version = version
      @triplet = triplet
      @work_dir = work_dir
      @tar = tar
    end

    # Extract the archive into a pristine tree, prune, and return the
    # staged root.
    def stage(archive)
      root = File.join(@work_dir, "root")
      FileUtils.rm_rf(root)
      FileUtils.mkdir_p(root)
      out, err, status = Open3.capture3(@tar, "-xf", archive, "-C", root)
      unless status.success?
        raise TebakoDotnetBuilder::Error.new("extract of #{archive} failed: #{err.strip}", 103)
      end

      assert_tree_shape(root)
      prune(root)
      root
    end

    # The POSIX preload shim rides the image (the layout's preload_shim
    # grant; the driver arms DYLD_INSERT_LIBRARIES / LD_PRELOAD from it
    # so the jail's host-IO binding survives the exec into the muxer —
    # the openjdk grammar). Declared-but-absent is exit 78, so the file
    # lands in the same pass.
    def stage_preload_shim(root, shim)
      ext = TebakoDotnetBuilder::Platform.shim_extension_for(@triplet)
      dest_dir = File.join(root, "lib", "tebako")
      FileUtils.mkdir_p(dest_dir)
      FileUtils.cp(shim, File.join(dest_dir, "libtfs_preload.#{ext}"))
      FileUtils.chmod(0o755, File.join(dest_dir, "libtfs_preload.#{ext}"))
    end

    # Render the two cards into the staged tree. blob_sha256 stays
    # zeroed in-image (spec 03 §7's fixed-point rule); the sibling
    # release-tier manifest re-renders it after mkimage.
    def render_manifests(root, created:)
      values = manifest_values(created: created)
      render(File.join(root, "__tpkg__", "manifest.yaml"), template("runtime.yaml"), values)
      render(File.join(root, "lib", "tebako", "layout.yaml"), template("layout.yaml"), values)
    end

    private

    # The SDK tree's shape is asserted BEFORE pruning so a drifted
    # archive fails on the invariant it broke, never on a downstream
    # absence. Exactly one sdk/<ver> dir (the SDK feature band) is
    # discovered, never computed.
    def assert_tree_shape(root)
      muxer = "dotnet#{TebakoDotnetBuilder::Platform.exe_suffix_for(@triplet)}"
      kept = [
        muxer, "host/fxr", "sdk", "sdk-manifests", "shared", "templates",
        "packs", "shared/Microsoft.NETCore.App", "LICENSE.txt", "ThirdPartyNotices.txt"
      ]
      kept.each do |rel|
        next if File.exist?(File.join(root, rel))

        raise TebakoDotnetBuilder::Error.new(
          "the staged SDK tree carries no #{rel} — Microsoft's archive shape drifted against the prune policy", 103
        )
      end

      rid = @pins.source(@version, @triplet).rid
      %W[
        packs/Microsoft.NETCore.App.Ref
        packs/Microsoft.NETCore.App.Host.#{rid}
      ].each do |rel|
        next if File.directory?(File.join(root, rel))

        raise TebakoDotnetBuilder::Error.new(
          "the staged SDK tree carries no #{rel} — the offline-compile pack the skeleton scope needs is missing", 103
        )
      end

      sdk_dirs = Dir.children(File.join(root, "sdk")).select { |d| File.directory?(File.join(root, "sdk", d)) }
      unless sdk_dirs.length == 1
        raise TebakoDotnetBuilder::Error.new(
          "the staged SDK tree carries sdk/ dirs #{sdk_dirs.inspect} — exactly one feature-band dir is the contract", 103
        )
      end
    end

    def prune(root)
      sdk_dir = Dir.children(File.join(root, "sdk")).first
      paths = PRUNE_PATHS + PRUNE_SDK_PATHS.map { |p| File.join("sdk", sdk_dir, p) }
      paths.each do |rel|
        target = File.join(root, rel)
        unless File.exist?(target)
          raise TebakoDotnetBuilder::Error.new(
            "prune path #{rel} is absent from the staged SDK tree — the policy names bytes Microsoft stopped shipping", 103
          )
        end

        FileUtils.rm_rf(target)
        raise TebakoDotnetBuilder::Error.new("prune of #{rel} failed", 103) if File.exist?(target)
      end
    end

    def manifest_values(created:)
      source = @pins.source(@version, @triplet)
      line = @pins.line(@version)
      exe_suffix = TebakoDotnetBuilder::Platform.exe_suffix_for(@triplet)
      shim_ext = TebakoDotnetBuilder::Platform.shim_extension_for(@triplet)
      preload_decl = if shim_ext
                       "preload_shim: \"lib/tebako/libtfs_preload.#{shim_ext}\""
                     else
                       "# (preload_shim omitted — no preload mechanism on windows)"
                     end
      {
        "@@VERSION@@" => @version,
        "@@RUNTIME_VERSION@@" => @pins.runtime_version(@version),
        "@@CREATED@@" => created,
        "@@UPSTREAM_SHA256@@" => source.sha256,
        "@@UPSTREAM_COMMIT@@" => "dotnet-sdk-#{@version}",
        "@@BLOB_SHA256@@" => "0" * 64,
        "@@ENGINE@@" => "dotnet",
        "@@ABI_LINE@@" => line,
        "@@API_VERSION@@" => line,
        "@@TRIPLET@@" => @triplet,
        "@@IMPLEMENTATION@@" => "dotnet",
        "@@MOUNT_ROOT@@" => TebakoDotnetBuilder::Platform.mount_root_for(@triplet),
        "@@INTERPRETER@@" => "/dotnet#{exe_suffix}",
        "@@EXE_SUFFIX@@" => exe_suffix,
        "@@PRELOAD_SHIM_DECL@@" => preload_decl,
        "@@ENTRYPOINTS_YAML@@" => "    - {name: \"dotnet\", path: \"/dotnet#{exe_suffix}\"}\n"
      }
    end

    def template(name)
      # The templates carry UTF-8 prose; a C-locale container would
      # otherwise read them as US-ASCII and fail the token scan on
      # invalid bytes.
      File.read(File.expand_path("../../../manifests/#{name}", __dir__), encoding: "UTF-8")
    end

    def render(dest, body, values)
      FileUtils.mkdir_p(File.dirname(dest))
      rendered = values.reduce(body) { |text, (token, value)| text.gsub(token, value) }
      if (left = rendered.scan(/@@[A-Z_]+@@/).uniq).any?
        raise TebakoDotnetBuilder::Error.new("manifest render left tokens unfilled: #{left.join(', ')}", 103)
      end

      File.write(dest, rendered)
    end
  end
end
