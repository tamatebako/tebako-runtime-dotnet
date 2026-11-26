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

module TebakoDotnetBuilder
  # The platform grammar (tebako-runtime-php's Platform role, at the
  # repack factory's scope): the single owner of the triplet <->
  # asset-platform <-> RID mappings the matrix planner, the contract
  # gate, and the build tooling all read. The mapping itself is owned by
  # tpkg::Platform (tamatebako/tebako, docs/spec/03 §3 — the single
  # triplet <-> release-asset-name owner); this mirrors it, and a drift
  # fails loudly at the boot smoke (the driver refuses an unknown
  # triplet at manifest parse, exit 65).
  #
  # The vocabulary is carried COMPLETE (all eight spec-03 triplets the
  # ecosystem grammar knows): versions.yml pins only what Microsoft
  # ships and the matrix only legs what the workflow declares, so a new
  # platform's increment adds a pin + a matrix row, never a
  # re-derivation here.
  class Platform
    # The spec 03 §3 vcpkg-form triplets (the in-image manifest's
    # provides.provides[].platform grammar — and versions.yml's sources
    # keys).
    TRIPLETS = %w[
      x86_64-linux-gnu
      aarch64-linux-gnu
      x86_64-linux-musl
      aarch64-linux-musl
      aarch64-macos
      x86_64-macos
      x86_64-windows-ucrt
      aarch64-windows-ucrt
    ].freeze

    # triplet -> release platform id (the pair stem's platform segment:
    # tebako-runtime-<line>-dotnet-<sdk>-<asset_platform>, and the
    # contract.yml tools.sha256 pin keys — the wrapper/tfs/link-unit
    # asset names key on the same ids for POSIX). "windows-ucrt64"
    # carries no arch segment (tpkg's grammar, not derivable by
    # formula).
    ASSET_PLATFORMS = {
      "x86_64-linux-gnu" => "linux-gnu-x86_64",
      "aarch64-linux-gnu" => "linux-gnu-arm64",
      "x86_64-linux-musl" => "linux-musl-x86_64",
      "aarch64-linux-musl" => "linux-musl-arm64",
      "aarch64-macos" => "macos-arm64",
      "x86_64-macos" => "macos-x86_64",
      "x86_64-windows-ucrt" => "windows-ucrt64",
      "aarch64-windows-ucrt" => "windows-ucrt-arm64"
    }.freeze

    # The matrix.json (os, arch) vocabulary -> triplet (the planner's
    # env-row resolution; php's HOST_IDS grammar inverted).
    OS_ARCH_TRIPLETS = {
      %w[linux-gnu x86_64] => "x86_64-linux-gnu",
      %w[linux-gnu arm64] => "aarch64-linux-gnu",
      %w[linux-musl x86_64] => "x86_64-linux-musl",
      %w[linux-musl arm64] => "aarch64-linux-musl",
      %w[macos arm64] => "aarch64-macos",
      %w[macos x86_64] => "x86_64-macos",
      %w[windows x86_64] => "x86_64-windows-ucrt",
      %w[windows arm64] => "aarch64-windows-ucrt"
    }.freeze

    class << self
      def asset_platform_for(triplet)
        ASSET_PLATFORMS.fetch(triplet) do
          raise TebakoDotnetBuilder::Error.new("no asset platform for triplet '#{triplet}'", 112)
        end
      end

      def triplet_for(os_id, arch_id)
        OS_ARCH_TRIPLETS.fetch([os_id, arch_id]) do
          raise TebakoDotnetBuilder::Error.new("#{os_id}/#{arch_id}", 112)
        end
      end

      # The inverse lookup (the registry renderer's: a shard's `platform`
      # is an asset-platform id, the registry row keys the spec 03 §3
      # triplet — tools/registry_update.rb). Fail-closed: an id the
      # mapping does not know is a named error, never a silently wrong
      # registry row.
      def triplet_for_asset_platform(asset_platform)
        ASSET_PLATFORMS.key(asset_platform) ||
          raise(TebakoDotnetBuilder::Error.new("no spec 03 triplet for asset platform '#{asset_platform}'", 112))
      end

      def windows?(triplet)
        triplet.include?("windows")
      end

      def macos?(triplet)
        triplet.include?("macos")
      end

      # The exe suffix on the windows legs (empty elsewhere).
      def exe_suffix_for(triplet)
        windows?(triplet) ? ".exe" : ""
      end

      # The runtime mount root the layout card declares — must equal the
      # wrapper exe's compiled-in WRAPPER_RUNTIME_ROOT (a mismatch is
      # exit 78; crates/tebako-driver/src/wrapper.rs owns the value).
      def mount_root_for(triplet)
        windows?(triplet) ? "A:/t" : "/__tfs__"
      end

      # The preload shim's in-image extension following the platform's
      # dynamic-loader convention; nil on windows (no preload mechanism
      # there — the windows image omits the grant).
      def shim_extension_for(triplet)
        return nil if windows?(triplet)
        return "dylib" if macos?(triplet)

        "so"
      end
    end
  end
end
