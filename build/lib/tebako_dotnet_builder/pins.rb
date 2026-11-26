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

require "yaml"

module TebakoDotnetBuilder
  # versions.yml as a typed object: the .NET SDK source pins (this
  # factory's trust anchor — Microsoft publishes the compiled per-RID
  # builds; there is no source tree to pin against). Every read is a
  # named error on absence.
  class Pins
    # The one owner of the SDK version grammar (spec 00 §10):
    # schema/contract.schema.yml's catalog pattern mirrors it (asserted
    # by the lint gate passing on the same strings), and the
    # tebako-release gem's package-filename parse interpolates it through
    # this factory's adapter (scripts/release_adapter.rb) — nothing
    # re-derives it. SDK_LINE_GRAMMAR_SOURCE stays anchor-free: the gem
    # wraps the source in its own \A…\z package-name pattern
    # (uploader.rb's parse_package_filename). The shape is
    # <major>.<minor>.<feature band><patch digits> (10.0.404 = the 10.0.4xx
    # band, patch 04) — plain digits/dots, no prerelease labels (a
    # preview SDK would be its own deliberate increment).
    SDK_LINE_GRAMMAR_SOURCE = '\d+\.\d+\.\d{3,}'

    # One pinned SDK archive: the url, the sha256 the fetch verifies,
    # Microsoft's own published sha512 (the pin-time cross-check
    # anchor), and the .NET RID (the apphost pack name and the boot
    # smoke's --info assertion).
    Source = Struct.new(:rid, :url, :sha256, :upstream_sha512, keyword_init: true)

    attr_reader :path

    def initialize(path)
      @path = path
      data = YAML.load_file(path)
      @versions = data.is_a?(Hash) ? data["versions"] : nil
      unless @versions.is_a?(Hash)
        raise TebakoDotnetBuilder::Error.new("#{path} is not a versions mapping (versions: <v>: …)", 101)
      end
    end

    def pinned_versions
      @versions.keys
    end

    def line(version)
      record(version).fetch("line") { missing(version, "line") }
    end

    # The Microsoft.NETCore.App shared-framework version the pinned SDK
    # carries (the boot smoke's --info assertion).
    def runtime_version(version)
      record(version).fetch("runtime_version") { missing(version, "runtime_version") }
    end

    # The pinned archive for one spec-03 triplet. An absent pin is a
    # named error — per-triplet availability is recorded honestly in
    # versions.yml, never guessed here.
    def source(version, triplet)
      sources = record(version).fetch("sources") { missing(version, "sources") }
      entry = sources.fetch(triplet) do
        raise TebakoDotnetBuilder::Error.new(
          "#{@path}: .NET SDK #{version} carries no source pin for triplet #{triplet}", 101
        )
      end
      Source.new(
        rid: entry.fetch("rid") { missing(version, "sources.#{triplet}.rid") },
        url: entry.fetch("url") { missing(version, "sources.#{triplet}.url") },
        sha256: entry.fetch("sha256") { missing(version, "sources.#{triplet}.sha256") },
        upstream_sha512: entry.fetch("upstream_sha512") { missing(version, "sources.#{triplet}.upstream_sha512") }
      )
    end

    private

    def record(version)
      @versions.fetch(version) do
        raise TebakoDotnetBuilder::Error.new("#{@path}: no pin for .NET SDK #{version}", 101)
      end
    end

    def missing(version, key)
      raise TebakoDotnetBuilder::Error.new("#{@path}: .NET SDK #{version} carries no #{key}", 101)
    end
  end
end
