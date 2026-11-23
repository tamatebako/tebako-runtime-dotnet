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

# Contract check (tebako-runtime-php's scripts/check_contract.rb port,
# .NET edition): validates contract.yml against
# schema/contract.schema.yml, cross-checks the version sets (tidy/full
# must be subsets of the catalog), cross-locks the catalog against
# versions.yml's source pins (BOTH directions — a version that builds
# but has no pin, or a pin no leg builds, is a config bug), proves every
# triplet the matrix vocabulary legs has a source pin for every catalog
# version, validates each pin's shape (https url, 64-hex sha256, 128-hex
# upstream_sha512, a RID the url carries), and locks the TWO
# representations of the contract version:
#   - contract.yml at the repo root — the release pipeline's source of
#     truth
#   - TEBAKO_CONTRACT_VERSION in the CONSUMED driver's source —
#     crates/tebako-driver/src/lib.rs at contract.yml's link_unit_release
#     pin (this factory consumes the product's published wrapper/link
#     unit; there is no in-repo driver source to read). TEBAKO_DRIVER_SRC
#     points the arm at a local file instead (offline runs).
# A contract bump edits both in the same commit; the arm fails closed on
# a fetch/read failure (a parity check that cannot see its second
# representation proves nothing).

require "bundler/setup"
require "fileutils"
require "json"
require "json_schemer"
require "pathname"
require "yaml"

REPO_ROOT = Pathname.new(File.expand_path("..", __dir__)).freeze
$LOAD_PATH.unshift(REPO_ROOT.join("build", "lib").to_s)

require "tebako_dotnet_builder"

class ContractCheck
  CONTRACT_YML = REPO_ROOT.join("contract.yml").freeze
  SCHEMA_YML = REPO_ROOT.join("schema", "contract.schema.yml").freeze
  VERSIONS_YML = REPO_ROOT.join("versions.yml").freeze
  MATRIX_JSON = REPO_ROOT.join(".github", "matrix.json").freeze

  # The Rust form the arm regexes (crates/tebako-driver/src/lib.rs in the
  # tebako product repo — the contract-2 driver, embedded in the consumed
  # wrapper exe).
  RUST_PATTERN = /pub const TEBAKO_CONTRACT_VERSION: u32 = (\d+)/
  DRIVER_LIB_RS = "crates/tebako-driver/src/lib.rs"
  DRIVER_REPO = "tamatebako/tebako"

  def initialize(contract_yml: CONTRACT_YML, schema_yml: SCHEMA_YML, versions_yml: VERSIONS_YML,
                 matrix_json: MATRIX_JSON, driver_src: nil)
    @contract_yml = Pathname.new(contract_yml)
    @schema_yml = Pathname.new(schema_yml)
    @versions_yml = Pathname.new(versions_yml)
    @matrix_json = Pathname.new(matrix_json)
    @driver_src = driver_src || ENV.fetch("TEBAKO_DRIVER_SRC", nil)
  end

  # Human-readable violations: schema errors against contract.yml, a
  # version set naming a version the catalog does not carry, a
  # catalog/pin skew between contract.yml and versions.yml, a matrix-leg
  # triplet without a pin, a malformed pin, or a yaml/driver
  # contract-version disagreement. Empty when the contract is well-formed
  # and both representations agree.
  def errors
    violations = schema_errors
    violations += set_errors if violations.empty?
    violations += source_pin_errors if violations.empty?
    violations += matrix_pin_errors if violations.empty?
    violations += parity_errors if violations.empty?
    violations
  end

  def valid?
    errors.empty?
  end

  def contract_version
    data = YAML.load_file(@contract_yml)
    data.is_a?(Hash) ? data["contract_version"] : nil
  end

  # The fetch half of the parity arm, split out for the dedicated CI fetch
  # job: resolves the pinned driver source (read_url's bounded retry rides
  # along), refuses a body that carries no compiled-in constant (a 200
  # error page would otherwise poison every consuming gate with a
  # misleading mismatch), and writes it to dest. Returns the origin for
  # the log line.
  def fetch_driver_source(dest)
    body, origin = driver_source
    unless body.match(RUST_PATTERN)
      raise TebakoDotnetBuilder::Error.new(
        "#{origin} carries no `pub const TEBAKO_CONTRACT_VERSION: u32 = N;` — " \
        "the fetched body is not the driver's lib.rs; refusing to hand it to the parity gate", 1
      )
    end

    FileUtils.mkdir_p(File.dirname(dest))
    File.binwrite(dest, body)
    origin
  end

  private

  def schema_errors
    schemer = JSONSchemer.schema(YAML.load_file(@schema_yml))
    schemer.validate(YAML.load_file(@contract_yml)).map do |problem|
      "#{@contract_yml}: #{problem.fetch('error', problem.to_s)}"
    end
  end

  def set_errors
    sets = YAML.load_file(@contract_yml).fetch("dotnet")
    catalog = sets.fetch("catalog")
    %w[tidy full].flat_map do |set|
      (sets.fetch(set) - catalog).map do |version|
        "#{@contract_yml}: dotnet.#{set} names #{version}, which the catalog does not carry"
      end
    end
  end

  # The catalog <-> source-pin cross-lock (this factory IS the source-pin
  # owner — Microsoft publishes the compiled builds; there is no
  # tamatebako source factory for .NET).
  def source_pin_errors
    catalog = YAML.load_file(@contract_yml).fetch("dotnet").fetch("catalog")
    data = YAML.load_file(@versions_yml)
    pins = data.is_a?(Hash) ? data["versions"] : nil
    unless pins.is_a?(Hash)
      return ["#{@versions_yml} is not a versions mapping (versions: <v>: {line, runtime_version, sources})"]
    end

    violations = (catalog - pins.keys).map do |version|
      "#{@versions_yml}: .NET SDK #{version} is in the catalog but carries no source pin"
    end
    violations += (pins.keys - catalog).map do |version|
      "#{@versions_yml}: .NET SDK #{version} is pinned but the catalog never builds it"
    end
    pins.each do |version, pin|
      violations += pin_shape_errors(version, pin)
    end
    violations
  end

  def pin_shape_errors(version, pin)
    violations = []
    unless pin.is_a?(Hash)
      return ["#{@versions_yml}: .NET SDK #{version} is not a pin mapping (line, runtime_version, sources)"]
    end

    %w[line runtime_version].each do |key|
      violations << "#{@versions_yml}: .NET SDK #{version} carries no #{key}" unless pin[key].is_a?(String) && !pin[key].empty?
    end
    sources = pin["sources"]
    return violations + ["#{@versions_yml}: .NET SDK #{version} carries no sources map"] unless sources.is_a?(Hash) && !sources.empty?

    sources.each do |triplet, source|
      unless TebakoDotnetBuilder::Platform::TRIPLETS.include?(triplet)
        violations << "#{@versions_yml}: .NET SDK #{version} sources names unknown triplet #{triplet} " \
                      "(known: #{TebakoDotnetBuilder::Platform::TRIPLETS.join(', ')})"
        next
      end
      unless source.is_a?(Hash)
        violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} is not a source mapping"
        next
      end

      rid = source["rid"]
      url = source["url"]
      sha256 = source["sha256"]
      sha512 = source["upstream_sha512"]
      violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} carries no rid" if rid.to_s.empty?
      unless url.is_a?(String) && url.start_with?("https://")
        violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} pin carries no https url"
      end
      if url.is_a?(String) && !rid.to_s.empty? && !url.include?(rid)
        violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} url does not carry its rid #{rid} — the pin is suspect"
      end
      unless sha256.to_s.match?(/\A[0-9a-f]{64}\z/)
        violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} pin carries no sha256 (64 lowercase hex)"
      end
      unless sha512.to_s.match?(/\A[0-9a-f]{128}\z/)
        violations << "#{@versions_yml}: .NET SDK #{version} #{triplet} pin carries no upstream_sha512 " \
                      "(128 lowercase hex — Microsoft's published digest, the pin-time cross-check anchor)"
      end
    end
    violations
  end

  # The matrix-leg coverage arm: every triplet the leg vocabulary
  # (.github/matrix.json) declares must carry a source pin for EVERY
  # catalog version — a leg without its pin is a config bug caught here,
  # never mid-leg.
  def matrix_pin_errors
    catalog = YAML.load_file(@contract_yml).fetch("dotnet").fetch("catalog")
    pins = YAML.load_file(@versions_yml).fetch("versions")
    env = JSON.parse(File.read(@matrix_json)).fetch("env")
    env.flat_map do |row|
      triplet = TebakoDotnetBuilder::Platform.triplet_for(row.fetch("os"), row.fetch("arch"))
      catalog.filter_map do |version|
        sources = pins.fetch(version, {}).fetch("sources", {})
        next if sources.key?(triplet)

        "#{@versions_yml}: .NET SDK #{version} carries no pin for #{triplet}, which .github/matrix.json legs"
      end
    end
  rescue TebakoDotnetBuilder::Error => e
    ["#{@matrix_json}: #{e.message}"]
  end

  # The driver-source parity arm: an unreadable driver source (fails
  # closed), a missing compiled-in constant, or a yaml/driver
  # disagreement are all violations.
  def parity_errors
    body, origin = driver_source
    match = body.match(RUST_PATTERN)
    unless match
      return ["#{origin} carries no `pub const TEBAKO_CONTRACT_VERSION: u32 = N;` — " \
              "the driver must compile its contract version in"]
    end

    driver_version = match[1].to_i
    return [] if driver_version == contract_version

    ["contract.yml contract_version is #{contract_version} but TEBAKO_CONTRACT_VERSION in #{origin} " \
     "is #{driver_version} — a contract bump edits both in the same commit"]
  rescue StandardError => e
    ["the driver-source parity arm could not read its second representation: #{e.message} " \
     "(needs network to raw.githubusercontent.com or TEBAKO_DRIVER_SRC=<local lib.rs>; fails closed)"]
  end

  # [body, origin]: the TEBAKO_DRIVER_SRC local file when set, else the
  # pinned link_unit_release's driver source off raw.githubusercontent.com.
  def driver_source
    return [File.read(@driver_src), @driver_src] if @driver_src

    url = "https://raw.githubusercontent.com/#{DRIVER_REPO}/#{link_unit_release}/#{DRIVER_LIB_RS}"
    [TebakoDotnetBuilder::Fetcher.read_url(url, code: 1), url]
  end

  def link_unit_release
    release = YAML.load_file(@contract_yml)["link_unit_release"].to_s
    return release unless release.empty?

    raise "#{@contract_yml} carries no link_unit_release pin — the parity arm has no driver tag to read"
  end
end

if $PROGRAM_NAME == __FILE__
  # Every failure lands on two channels: a plain stderr line the raw log
  # always carries, and an ::error:: annotation whose payload is escaped
  # (the annotations channel drops unescaped %, CR, and LF).
  report = lambda do |message|
    warn "check_contract: #{message}"
    puts "::error::#{message.gsub('%', '%25').gsub("\r", '%0D').gsub("\n", '%0A')}"
  end

  begin
    check = ContractCheck.new
    if ARGV[0] == "--fetch-parity"
      # The dedicated fetch job's mode: resolve the pinned driver source
      # once per workflow call and write it for the artifact handoff — the
      # per-platform gates then read the artifact, never the network
      # (tebako-runtime-python#4's de-flake).
      dest = ARGV[1].to_s
      if dest.empty?
        report.call("usage: scripts/check_contract.rb --fetch-parity <dest>")
        exit 1
      end
      origin = check.fetch_driver_source(dest)
      puts "fetched #{origin} -> #{dest} (#{File.size(dest)} bytes)"
    elsif check.valid?
      puts "contract version #{check.contract_version}: contract.yml validates against schema/contract.schema.yml, " \
           "the catalog matches versions.yml's source pins, every matrix leg's triplet is pinned, and the " \
           "consumed driver's compiled-in TEBAKO_CONTRACT_VERSION agrees"
    else
      check.errors.each { |error| report.call(error) }
      exit 1
    end
  rescue StandardError => e
    report.call("contract check failed: #{e.message}")
    exit 1
  end
end
