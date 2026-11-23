#!/usr/bin/env ruby
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

# Compute the build-leg matrix for _build-platform.yml: the .NET SDK set
# (resolved from contract.yml — the same read scripts/versions performs)
# x the env vocabulary (.github/matrix.json — the php factory's grammar),
# sliced by the dispatch filters. Emits a GitHub Actions matrix JSON
# document on stdout. Stdlib only.
#
# Usage: compute_matrix.rb [--format matrix|env|dotnets]
#   matrix  (default) the GHA matrix document {"include": [leg, ...]} —
#           extra top-level keys are impossible (GHA would read them as
#           matrix variables), so the other two forms exist
#   env     the selected matrix.json rows as a JSON array (each +
#           triplet/asset_platform) — the future release job's
#           EXPECTED_ENV_MATRIX
#   dotnets the selected SDK versions as a JSON array — the future
#           release job's EXPECTED_DOTNET_MATRIX
#
# Filters (env vars, mirroring the other factories' dispatch grammar):
#   DOTNET_FILTER    full | tidy | catalog | comma-separated versions (default: full)
#   PLATFORM_FILTER  all | linux-gnu | linux-musl | macos | windows      (default: all)
#   ARCH_FILTER      all | x86_64 | arm64                                (default: all)
#
# Every leg carries:
#   dotnet / os / arch / host — the matrix coordinates
#   triplet                   — the spec 03 §3 triplet (versions.yml's
#                               sources keys; Platform::OS_ARCH_TRIPLETS)
#   asset_platform            — the pair stem's platform segment
#                               (tebako-runtime-<line>-dotnet-<sdk>-<id>)
#   exe_suffix                — ".exe" on windows, "" elsewhere
#   container                 — the tpkg-builder image the leg's build +
#                               smokes run inside (the musl leg: its musl
#                               binaries execute only under musl libc —
#                               the php/openjdk container-leg idiom);
#                               null on the runner-native legs
#   tar                       — the row's archiver: "tar" POSIX; the ucrt64
#                               bsdtar on windows x64 (GNU tar cannot read
#                               the .zip SDK archive), the in-box
#                               System32 tar.exe on windows arm64 (the
#                               openjdk idiom)
#
# Named errors, exit 64: an unknown platform/arch filter, an unknown
# --format, or a matrix.json row outside the known vocabulary is a config
# bug, never a skipped leg.

require "json"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__).freeze
$LOAD_PATH.unshift(File.join(REPO_ROOT, "build", "lib"))

require "tebako_dotnet_builder"

CONTRACT_YML = File.join(REPO_ROOT, "contract.yml").freeze
MATRIX_JSON = File.join(REPO_ROOT, ".github", "matrix.json").freeze

PLATFORMS = %w[linux-gnu linux-musl macos windows].freeze
ARCHES = %w[x86_64 arm64].freeze

def usage_error(message)
  warn "compute_matrix: #{message}"
  exit 64
end

format = "matrix"
if (idx = ARGV.index("--format"))
  format = ARGV[idx + 1].to_s
  usage_error "--format expects matrix | env | dotnets" unless %w[matrix env dotnets].include?(format)
elsif !ARGV.empty?
  usage_error "unknown argument(s): #{ARGV.join(', ')} (the only option is --format matrix|env|dotnets)"
end

contract = YAML.load_file(CONTRACT_YML)
dotnet_sets = contract.fetch("dotnet") { usage_error "#{CONTRACT_YML} carries no dotnet: catalog" }
catalog = dotnet_sets.fetch("catalog") { usage_error "#{CONTRACT_YML} dotnet: carries no catalog key" }

dotnet_filter = ENV.fetch("DOTNET_FILTER", "full")
dotnets =
  case dotnet_filter
  when "full", "tidy", "catalog"
    dotnet_sets.fetch(dotnet_filter) { usage_error "#{CONTRACT_YML} dotnet: carries no #{dotnet_filter} set" }
  when ""
    usage_error "DOTNET_FILTER is empty — expected full | tidy | catalog | a comma-separated version list"
  else
    versions = dotnet_filter.split(",").map(&:strip).reject(&:empty?)
    unknown = versions - catalog
    usage_error "unknown .NET SDK version(s) #{unknown.join(', ')} — catalog knows: #{catalog.join(', ')}" unless unknown.empty?
    versions
  end

platform_filter = ENV.fetch("PLATFORM_FILTER", "all")
unless platform_filter == "all" || PLATFORMS.include?(platform_filter)
  usage_error "unknown platform #{platform_filter.inspect} — expected all | #{PLATFORMS.join(' | ')}"
end

arch_filter = ENV.fetch("ARCH_FILTER", "all")
unless arch_filter == "all" || ARCHES.include?(arch_filter)
  usage_error "unknown arch #{arch_filter.inspect} — expected all | #{ARCHES.join(' | ')}"
end

env = JSON.parse(File.read(MATRIX_JSON)).fetch("env")

legs = []
selected_env = []
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  begin
    triplet = TebakoDotnetBuilder::Platform.triplet_for(os, arch)
  rescue TebakoDotnetBuilder::Error
    usage_error "matrix.json row #{row.inspect} is outside the known (os, arch) vocabulary"
  end
  asset_platform = TebakoDotnetBuilder::Platform.asset_platform_for(triplet)
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  dotnets.each do |dotnet|
    legs << {
      dotnet: dotnet,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      triplet: triplet,
      asset_platform: asset_platform,
      exe_suffix: TebakoDotnetBuilder::Platform.exe_suffix_for(triplet),
      container: row["container"],
      tar: row.fetch("tar", "tar")
    }
  end
  # The env row joins the expectations only when the row EMITTED a leg
  # (the php grammar: a gated row must not survive into env).
  selected_env << row.merge("triplet" => triplet, "asset_platform" => asset_platform) if dotnets.any?
end

case format
when "matrix" then puts JSON.generate({ include: legs })
when "env" then puts JSON.generate(selected_env)
when "dotnets" then puts JSON.generate(dotnets.select { |d| legs.any? { |leg| leg[:dotnet] == d } })
end
