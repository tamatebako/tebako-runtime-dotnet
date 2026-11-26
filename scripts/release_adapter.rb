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

# This factory's tebako-release declaration (ecosystem invariant 10: the
# release machinery's single owner is tamatebako/tebako-release-tooling —
# the gem the Gemfile pins at contract.yml's release_tooling). This file
# declares THIS factory's identity + policy through the gem's adapter
# seam; the machinery itself is never copied here. The tebako-release exe
# loads this file before dispatching (upload|sign). (tebako-runtime-r's
# scripts/release_adapter.rb port, .NET edition.)

$LOAD_PATH.unshift(File.expand_path("../build/lib", __dir__))
require "tebako_dotnet_builder"

# The factory's release policy, delegated to the models that own each
# grammar (spec 00 §10's single-owner rule; nothing here re-derives a
# name or a grammar). This repack ships no flavor lines and no DLL facet
# (the .NET SDK lives INSIDE the env image — the openjdk shape), so the
# adapter defaults carry those axes.
class DotnetReleaseAdapter < TebakoRelease::Adapter
  # The package-name grammar's SDK-version capture
  # (tebako-runtime-<line>-dotnet-<sdk>-<platform>). Pins owns the
  # grammar — LINE_GRAMMAR_SOURCE, never LINE_PATTERN.source: the gem's
  # parse wraps the source in its own \A…\z and numbers the captures, so
  # an anchored/named-group source would never match.
  def version_grammar_source
    TebakoDotnetBuilder::Pins::SDK_LINE_GRAMMAR_SOURCE
  end

  # tebako#716's language segment of the package-name grammar: ALWAYS
  # "dotnet" — this factory was born after the flip, so it has no
  # immutable pre-#716 line to keep composing (Builder::LANG_SEGMENT is
  # the same fact's build-side owner; tebako-runtime-r's adapter
  # rationale).
  def lang_name
    TebakoDotnetBuilder::Builder::LANG_SEGMENT
  end
end

TebakoRelease.configure(
  repo: "tamatebako/tebako-runtime-dotnet",
  language: "dotnet",
  title_prefix: "Tebako .NET runtime packages",
  contract_yml: File.expand_path("../contract.yml", __dir__),
  adapter: DotnetReleaseAdapter.new
)
