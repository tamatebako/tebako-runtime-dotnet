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
require "json"
require "open3"
require "time"
require "tmpdir"
require "yaml"

module TebakoDotnetBuilder
  # The repack orchestrator (the openjdk tools/build grammar, ported to
  # the factory's Ruby model): fetch + verify the pinned SDK archive and
  # the pinned tebako toolchain -> stage + prune the env-image tree ->
  # image (tfs mkimage, the limnifs writer — the product default, never
  # a --format pin in callers) -> pair with the spec-29 wrapper exe ->
  # sidecars + the release shard -> read-back gates -> the
  # extracted-tree truth smoke. The deeper contract scenarios live in
  # tools/boot_smoke.
  #
  # Outputs land in runtime-packages/ (the boot smoke's
  # TEBAKO_RUNTIME_ROOT grammar): <stem> (the wrapper exe, 0755),
  # <stem>.tfs (+ .sha256 + .blksum.json + .blksum.json.sha256),
  # <stem>.contract.yaml (the era-2 provenance card the tebako-release
  # gem folds into the published shard — spec 18 C2),
  # <stem>.manifest.json (the in-leg release shard), and
  # payload-<triplet>.yaml (the release-tier manifest with the real
  # blob sha).
  class Builder
    # tebako#716's language segment of the package-name grammar
    # (`tebako-runtime-<line>-dotnet-<sdk>-<platform>`): ALWAYS "dotnet"
    # — this factory was born after the flip, so it has no immutable
    # pre-#716 line to keep composing (the php/r factories' rationale).
    # The release adapter (scripts/release_adapter.rb) reads the same
    # constant — nothing re-derives it.
    LANG_SEGMENT = "dotnet"

    # The era-2 contract card constants (spec 18 C2): what this factory
    # builds. Written into every package's .contract.yaml sidecar.
    CONTRACT_CARD = { "contract_era" => 2, "image_layout" => 1 }.freeze

    def initialize(repo_root:, version:, triplet:, work_dir: nil, out_dir: nil, tar: "tar")
      @repo_root = repo_root
      @version = version
      @triplet = triplet
      @tar = tar
      @work_dir = work_dir || File.join(repo_root, ".build", "work-#{triplet}")
      @out_dir = out_dir || File.join(repo_root, "runtime-packages")
      @contract = TebakoDotnetBuilder::Contract.new(File.join(repo_root, "contract.yml"))
      @pins = TebakoDotnetBuilder::Pins.new(File.join(repo_root, "versions.yml"))
    end

    def build
      line = @contract.tebako_line
      asset_platform = TebakoDotnetBuilder::Platform.asset_platform_for(@triplet)
      exe_suffix = TebakoDotnetBuilder::Platform.exe_suffix_for(@triplet)
      stem = "tebako-runtime-#{line}-#{LANG_SEGMENT}-#{@version}-#{asset_platform}"
      source = @pins.source(@version, @triplet)

      step("fetch + sha256-verify the .NET SDK #{@version} (#{@triplet})")
      archive = TebakoDotnetBuilder::Fetcher.download(
        source.url, File.join(downloads_dir, File.basename(source.url)), sha256: source.sha256
      )
      puts "archive: #{archive}"
      puts "sha256:  #{source.sha256}"

      step("stage the tebako toolchain (#{@contract.link_unit_release}, pin-verified)")
      toolchain = TebakoDotnetBuilder::Toolchain.new(
        @contract, asset_platform, exe_suffix, downloads_dir
      ).stage(posix: !TebakoDotnetBuilder::Platform.windows?(@triplet))
      puts "wrapper: #{toolchain.wrapper}"
      puts "tfs:     #{toolchain.tfs}"
      puts "shim:    #{toolchain.preload_shim}" if toolchain.preload_shim

      image_builder = TebakoDotnetBuilder::ImageBuilder.new(
        pins: @pins, version: @version, triplet: @triplet, work_dir: @work_dir, tar: @tar
      )

      step("stage + prune the SDK tree (the declared skeleton scope)")
      root = image_builder.stage(archive)
      image_builder.stage_preload_shim(root, toolchain.preload_shim) if toolchain.preload_shim

      step("embed /__tpkg__/manifest.yaml + /lib/tebako/layout.yaml")
      image_builder.render_manifests(root, created: created_timestamp)

      step("tfs mkimage (the in-process writer — limnifs, the product default)")
      image = File.join(@out_dir, "#{stem}.tfs")
      FileUtils.mkdir_p(@out_dir)
      FileUtils.rm_f(image)
      run(toolchain.tfs, "mkimage", "--format", "limnifs", root, "--output", image)
      image_sha = TebakoDotnetBuilder::Fetcher.sha256_of(image)
      puts "image:  #{image}"
      puts "sha256: #{image_sha}"

      step("blksum sidecar (the lazy mount's per-group digests, spec 39 §3)")
      run(toolchain.tfs, "blksum", image)
      blksum = "#{image}.blksum.json"
      unless File.file?(blksum)
        raise TebakoDotnetBuilder::Error.new("tfs blksum produced no #{blksum}", 103)
      end

      blksum_sha = TebakoDotnetBuilder::Fetcher.sha256_of(blksum)

      step("pair the wrapper exe (#{stem}#{exe_suffix})")
      exe = File.join(@out_dir, "#{stem}#{exe_suffix}")
      FileUtils.cp(toolchain.wrapper, exe)
      FileUtils.chmod(0o755, exe)
      exe_sha = TebakoDotnetBuilder::Fetcher.sha256_of(exe)

      step("sidecars (.sha256) + the release shard (<stem>.manifest.json)")
      write_sidecar("#{image}.sha256", image_sha, "#{stem}.tfs")
      write_sidecar("#{blksum}.sha256", blksum_sha, "#{stem}.tfs.blksum.json")
      write_sidecar("#{exe}.sha256", exe_sha, "#{stem}#{exe_suffix}")
      write_shard(stem, exe, exe_sha, image, image_sha, blksum, blksum_sha,
                  asset_platform: asset_platform, exe_suffix: exe_suffix, source: source)
      write_contract_sidecar(exe, asset_platform: asset_platform, exe_suffix: exe_suffix, source: source)

      read_back(toolchain.tfs, image)

      step("sibling manifest (release tier: real blob sha)")
      sibling = File.join(@out_dir, "payload-#{@triplet}.yaml")
      body = File.read(File.join(root, "__tpkg__", "manifest.yaml"), encoding: "UTF-8")
      rendered = body.sub(/blob_sha256: "[0]{64}"/, "blob_sha256: \"#{image_sha}\"")
      raise TebakoDotnetBuilder::Error.new("the in-image manifest's zeroed blob digest did not re-render", 103) if rendered == body

      File.write(sibling, rendered)
      puts "manifest: #{sibling}"

      step("extracted-tree smoke (the staged muxer answers --info)")
      extracted_smoke(toolchain.tfs, image)

      puts "\nbuild OK: #{stem}"
      { stem: stem, exe: exe, image: image }
    end

    private

    attr_reader :contract, :pins

    def downloads_dir
      File.join(@repo_root, ".build", "downloads")
    end

    # The run-wide build timestamp (ruby#381's idiom, the php factory's
    # shape): the workflow exports the HEAD commit's epoch so two runs of
    # the same tree stamp the image manifest identically; unset falls to
    # epoch 0 (the tfs-cli mkimage convention) so a local build is
    # deterministic too. A malformed value is a named error, never a
    # silent wall-clock fallback.
    def created_timestamp
      Time.at(sde_epoch).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def sde_epoch
      sde = ENV.fetch("SOURCE_DATE_EPOCH", nil)
      return 0 if sde.nil? || sde.empty?

      Integer(sde, 10)
    rescue ArgumentError
      raise TebakoDotnetBuilder::Error.new(
        "SOURCE_DATE_EPOCH is malformed (#{sde.inspect} — whole seconds since the epoch)", 64
      )
    end

    def step(message)
      puts "\n== #{message}"
    end

    def run(*argv)
      out, err, status = Open3.capture3(*argv)
      return if status.success?

      raise TebakoDotnetBuilder::Error.new("#{argv.join(' ')} failed: #{err.strip} #{out.strip}".strip, 103)
    end

    def write_sidecar(path, sha, name)
      File.write(path, "#{sha}  #{name}\n")
    end

    def write_shard(stem, exe, exe_sha, image, image_sha, blksum, blksum_sha,
                    asset_platform:, exe_suffix:, source:)
      line = @contract.tebako_line
      shard = {
        tebako_version: line,
        contract_era: 2,
        contract_version: @contract.contract_version,
        dotnet_version: @version,
        dotnet_runtime_version: @pins.runtime_version(@version),
        implementation: "dotnet",
        capabilities: [],
        platform: asset_platform,
        filename: "#{stem}#{exe_suffix}",
        sha256: exe_sha,
        size_bytes: File.size(exe),
        mount_root: TebakoDotnetBuilder::Platform.mount_root_for(@triplet),
        image_layout: 1,
        built_from: {
          release: "tamatebako/tebako-runtime-dotnet@#{ENV.fetch('GITHUB_REF_NAME', 'local')}",
          sources: [{ name: File.basename(source.url), sha256: source.sha256 }]
        },
        image: {
          filename: "#{stem}.tfs",
          sha256: image_sha,
          size_bytes: File.size(image),
          blksum: { filename: "#{stem}.tfs.blksum.json", sha256: blksum_sha }
        }
      }
      path = File.join(@out_dir, "#{stem}.manifest.json")
      File.write(path, "#{JSON.pretty_generate(shard)}\n")
      puts "shard: #{path}"
    end

    # The era-2 contract provenance (spec 18 C2) as
    # `<exe>.contract.yaml` — the tebako-release gem's uploader refuses a
    # package without it (fail-closed, S11/S16), folding contract_era /
    # mount_root / image_layout / built_from into the shard it renders
    # publish-side (the in-leg shard above stays build evidence; the
    # release's shard is the gem's render — spec 13 §2a). built_from
    # names the consumed SDK archive with its verified sha256 and the pin
    # file that anchored it; the additive link_unit block names the
    # consumed product release + the wrapper asset (open parse —
    # consumers that predate the key ignore it).
    def write_contract_sidecar(exe, asset_platform:, exe_suffix:, source:)
      card = CONTRACT_CARD.merge(
        "mount_root" => TebakoDotnetBuilder::Platform.mount_root_for(@triplet),
        "built_from" => {
          "pin" => "versions.yml",
          "sources" => [{ "name" => File.basename(source.url), "sha256" => source.sha256 }]
        },
        "link_unit" => {
          "release" => @contract.link_unit_release,
          "asset" => "tebako-runtime-launcher-#{@contract.tebako_line}-#{asset_platform}#{exe_suffix}"
        }
      )
      path = "#{exe.sub(/\.exe\z/, "")}.contract.yaml"
      File.write(path, YAML.dump(card))
      puts "contract card: #{path}"
    end

    # A broken pair fails THIS leg, never a publish step (the openjdk
    # read-back grammar): re-read the image with the same tfs CLI that
    # wrote it — the embedded manifest exists and validates, the layout
    # card is present, the declared entrypoint resolves, and the prune
    # policy held inside the image.
    def read_back(tfs, image)
      step("read-back: embedded manifest validates, layout + declared entrypoint + prune policy present")
      exe_suffix = TebakoDotnetBuilder::Platform.exe_suffix_for(@triplet)
      ["/__tpkg__/manifest.yaml", "/lib/tebako/layout.yaml", "/dotnet#{exe_suffix}"].each do |vfs|
        stat!(tfs, image, vfs)
        puts "read-back: #{vfs} present"
      end
      info, status = Open3.capture2e(tfs, "info", "--json", image)
      unless status.success?
        raise TebakoDotnetBuilder::Error.new("read-back FAILED: tfs info cannot read #{image}", 103)
      end

      if info.include?('"manifest_error"')
        warn info.each_line.grep(/manifest_error/)
        raise TebakoDotnetBuilder::Error.new("read-back FAILED: the embedded manifest does not validate", 103)
      end

      ImageBuilder::PRUNE_PATHS.each do |rel|
        out, status = Open3.capture2e(tfs, "stat", image, "/#{rel}")
        next unless status.success?

        raise TebakoDotnetBuilder::Error.new(
          "read-back FAILED: pruned path /#{rel} is present in the image (#{out.strip})", 103
        )
      end
      puts "read-back: the prune policy held (#{ImageBuilder::PRUNE_PATHS.length + ImageBuilder::PRUNE_SDK_PATHS.length} paths absent)"
    end

    def stat!(tfs, image, vfs)
      _out, err, status = Open3.capture3(tfs, "stat", image, vfs)
      return if status.success?

      raise TebakoDotnetBuilder::Error.new("read-back FAILED: no #{vfs} in #{image}: #{err.strip}", 103)
    end

    # The repack's truth gate: extract the image on the host and ask the
    # staged muxer for its own inventory — the SDK version the recipe
    # pins and the shared runtime it carries must both answer (--info
    # exits 0 for any dotnet, so only a content check catches a
    # wrong-tree stage).
    def extracted_smoke(tfs, image)
      Dir.mktmpdir("tebako-dotnet-extract") do |tmp|
        run(tfs, "extract", image, "-d", tmp)
        muxer = File.join(tmp, "dotnet#{TebakoDotnetBuilder::Platform.exe_suffix_for(@triplet)}")
        out, err, status = Open3.capture3(dotnet_env, muxer, "--info")
        unless status.success?
          raise TebakoDotnetBuilder::Error.new("dotnet --info failed on the extracted tree: #{err.strip}\n#{out}", 104)
        end

        want_runtime = @pins.runtime_version(@version)
        {
          "the pinned SDK version" => /#{Regexp.escape(@version)}\s+\[|\.NET SDK:\s*$(?:.|\n)*?Version:\s+#{Regexp.escape(@version)}/m,
          "the carried shared runtime" => /Microsoft\.NETCore\.App #{Regexp.escape(want_runtime)}\s+\[/
        }.each do |what, pattern|
          next if out.match?(pattern)

          raise TebakoDotnetBuilder::Error.new(
            "extracted smoke: --info names no #{what} (want #{@version} / #{want_runtime})\n#{out}", 104
          )
        end
        puts out.each_line.grep(/Version:|Microsoft\.NETCore\.App #{Regexp.escape(want_runtime)}/).first(4).join
      end
    end

    # The hermetic dotnet CLI environment for every smoke: no telemetry,
    # no logo, no first-run side effects beyond the scratch HOME under
    # the build workspace.
    def dotnet_env
      home = File.join(@work_dir, "smoke-home")
      FileUtils.mkdir_p(home)
      {
        "HOME" => home,
        "DOTNET_CLI_TELEMETRY_OPTOUT" => "1",
        "DOTNET_NOLOGO" => "1",
        "DOTNET_SKIP_FIRST_TIME_EXPERIENCE" => "1"
      }
    end
  end
end
