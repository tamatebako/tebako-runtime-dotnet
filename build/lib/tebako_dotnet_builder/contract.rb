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
  # contract.yml as a typed object (tebako-runtime-php's Contract role):
  # the repo's pin SSOT — the bootstrap <-> runtime contract version, the
  # consumed tamatebako/tebako release, the per-platform toolchain
  # digests, and the .NET SDK version catalog. Every read is a named
  # error on absence, never a nil that drifts downstream.
  class Contract
    attr_reader :path

    def initialize(path)
      @path = path
      @data = YAML.load_file(path)
      raise TebakoDotnetBuilder::Error.new("#{path} is not a contract mapping") unless @data.is_a?(Hash)
    end

    def contract_version
      fetch("contract_version")
    end

    # The tamatebako/tebako release tag the legs consume ("v2.8.83").
    def link_unit_release
      fetch("link_unit_release")
    end

    # The bare product line ("2.8.83") — the pair stem's tebako segment
    # and the release tag convention ("the tag IS the tebako product
    # line", the openjdk/trr grammar).
    def tebako_line
      link_unit_release.sub(/\Av/, "")
    end

    def tools_repo
      tools.fetch("repo") { missing("tools.repo") }
    end

    # The recorded digest for one tool (wrapper | tfs | link-unit) on one
    # asset-platform id. An absent pin is a named error — the leg that
    # needs a platform's tool pins lands them in the same commit (never a
    # silent skip, never a guess).
    def tool_sha256(tool, asset_platform)
      digests = tools.fetch("sha256") { missing("tools.sha256") }
                    .fetch(tool) { missing("tools.sha256.#{tool}") }
      digests.fetch(asset_platform) do
        missing("tools.sha256.#{tool}.#{asset_platform} (pin it in contract.yml with the platform's leg)")
      end
    end

    def catalog
      dotnet.fetch("catalog") { missing("dotnet.catalog") }
    end

    def set(name)
      dotnet.fetch(name) { missing("dotnet.#{name}") }
    end

    private

    def tools
      @tools ||= @data.fetch("tools") { missing("tools") }
    end

    def dotnet
      @dotnet ||= @data.fetch("dotnet") { missing("dotnet") }
    end

    def fetch(key)
      @data.fetch(key) { missing(key) }
    end

    def missing(key)
      raise TebakoDotnetBuilder::Error.new("#{@path} carries no #{key} pin", 101)
    end
  end
end
