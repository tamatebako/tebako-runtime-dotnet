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
  # The consumed tebako toolchain (the product release's published
  # binaries — releases are the interface; this factory NEVER builds the
  # driver stack from source): the spec-29 wrapper exe
  # (tebako-runtime-launcher — the pair's process entry point), the tfs
  # CLI (the in-process imager), and on POSIX the link-unit tarball (its
  # libtfs_preload rides the image so the jail's host-IO binding
  # survives the exec into the dotnet muxer — the openjdk grammar).
  #
  # Trust anchors: every download verifies against the contract.yml
  # tools.sha256 pin; the wrapper and tfs pins are ADDITIONALLY
  # cross-checked against the release's own SHA256SUMS (both anchored —
  # the node grammar). The link-unit tarballs are not in that monolith,
  # so their recorded pin is the single anchor.
  class Toolchain
    Result = Struct.new(:wrapper, :tfs, :preload_shim, keyword_init: true)

    def initialize(contract, asset_platform, exe_suffix, downloads_dir)
      @contract = contract
      @asset_platform = asset_platform
      @exe_suffix = exe_suffix
      @dir = downloads_dir
    end

    # Fetch + verify every tool this leg consumes. POSIX legs also stage
    # the link-unit's preload shim; windows legs consume neither the unit
    # nor a shim (exec-cache is the only windows mechanism — the image
    # omits the grant).
    def stage(posix:)
      line = @contract.tebako_line
      wrapper_asset = "tebako-runtime-launcher-#{line}-#{@asset_platform}#{@exe_suffix}"
      tfs_asset = "tfs-#{line}-#{@asset_platform}#{@exe_suffix}"
      sums = sha256sums
      wrapper = fetch_pinned(wrapper_asset, @contract.tool_sha256("wrapper", @asset_platform), sums: sums)
      tfs = fetch_pinned(tfs_asset, @contract.tool_sha256("tfs", @asset_platform), sums: sums)
      FileUtils.chmod(0o755, [wrapper, tfs])

      shim = nil
      if posix
        unit_asset = "link-unit-#{line}-#{@asset_platform}.tar.gz"
        unit = fetch_pinned(unit_asset, @contract.tool_sha256("link-unit", @asset_platform), sums: nil)
        shim = extract_preload_shim(unit)
      end
      Result.new(wrapper: wrapper, tfs: tfs, preload_shim: shim)
    end

    private

    # The release's own SHA256SUMS — the wrapper/tfs pins' second anchor
    # (a pin that disagrees with the release's sums is a supply-chain
    # event, named here).
    def sha256sums
      @sha256sums ||= begin
        url = "#{release_base}/SHA256SUMS"
        body = TebakoDotnetBuilder::Fetcher.read_url(url, code: 102)
        body.each_line.to_h do |line|
          digest, name = line.strip.split(/\s+/, 2)
          [name, digest]
        end
      end
    end

    def release_base
      "https://github.com/#{@contract.tools_repo}/releases/download/#{@contract.link_unit_release}"
    end

    def fetch_pinned(asset, pin, sums:)
      if sums
        recorded = sums.fetch(asset) do
          raise TebakoDotnetBuilder::Error.new(
            "the pinned release's SHA256SUMS carries no #{asset} entry — the pin has no second anchor", 102
          )
        end
        unless recorded == pin
          raise TebakoDotnetBuilder::Error.new(
            "pin mismatch for #{asset}: contract.yml=#{pin} release SHA256SUMS=#{recorded}", 102
          )
        end
      end
      dest = File.join(@dir, asset)
      TebakoDotnetBuilder::Fetcher.download("#{release_base}/#{asset}", dest, sha256: pin)
    end

    # The link-unit tarball nests its payload under
    # link-unit-<asset_platform>/; the shim the layout grant names is
    # libtfs_preload.<ext> (libtfs_preload.a is the static form the fs-TU
    # link consumed in the source-build factories — NOT what the image
    # stages).
    def extract_preload_shim(unit)
      ext = @asset_platform.start_with?("macos") ? "dylib" : "so"
      inner = "link-unit-#{@asset_platform}/libtfs_preload.#{ext}"
      out, err, status = Open3.capture3("tar", "-xzf", unit, "-C", @dir, inner)
      unless status.success?
        raise TebakoDotnetBuilder::Error.new(
          "the link-unit tarball carries no #{inner}: #{err.strip} — the preload_shim grant would be exit-78 empty", 102
        )
      end

      shim = File.join(@dir, inner)
      FileUtils.chmod(0o755, shim)
      shim
    end
  end
end
